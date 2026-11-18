import 'reflect-metadata';
import { PrismaClient } from '@prisma/client';

async function main(): Promise<void> {
  const base = process.env.DATABASE_URL;
  if (!base) throw new Error('DATABASE_URL is required');
  const url = base.includes('application_name=')
    ? base
    : `${base}&application_name=pool-lock-child`;
  const prisma = new PrismaClient({ datasources: { db: { url } } });
  await prisma.$connect();
  const keys = Array.from({ length: 8 }, (_, i) => `pool-lock-${process.pid}-${i}`);
  await Promise.all(
    keys.map(async (key) => {
      await prisma.$executeRaw`SELECT pg_advisory_lock(hashtextextended(${key}, 0))`;
      await new Promise((resolve) => setTimeout(resolve, 150));
      await prisma.$executeRaw`SELECT pg_advisory_unlock(hashtextextended(${key}, 0))`;
    }),
  );
  const rows = await prisma.$queryRaw<Array<{ n: number }>>`
    SELECT count(*)::int AS n
    FROM pg_locks l
    JOIN pg_stat_activity a ON a.pid = l.pid
    WHERE l.locktype = 'advisory' AND a.application_name = 'pool-lock-child'
  `;
  process.stdout.write(`${JSON.stringify({ leftovers: Number(rows[0]?.n ?? -1) })}\n`);
  await prisma.$disconnect();
}

void main().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exit(1);
});
