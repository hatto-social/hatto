import 'reflect-metadata';
import { compose } from './compose';
import type { FaultPoint } from './faults';
import type { BodyStrategy } from './publish/publish.service';

async function main(): Promise<void> {
  const deckId = process.env.DECK_ID;
  const actorId = process.env.ACTOR_ID;
  const root = process.env.DECK_ROOT;
  if (!deckId || !actorId || !root) {
    throw new Error('DECK_ID, ACTOR_ID, and DECK_ROOT are required');
  }
  const fault = process.env.FAULT_POINT ? (process.env.FAULT_POINT as FaultPoint) : null;
  const gateAt = process.env.GATE_AT as FaultPoint | undefined;
  const { prisma, publish } = compose();
  await prisma.$connect();
  try {
    const result = await publish.publish({
      deckId,
      actorId,
      root,
      strategy: (process.env.STRATEGY as BodyStrategy | undefined) ?? 'immutable',
      pathStyle: process.env.PATH_STYLE === 'version' ? 'version' : 'unique',
      processLock: false,
      advisoryLock: process.env.ADVISORY_LOCK === '1',
      databaseUrl: process.env.DATABASE_URL,
      fault,
      faultMode: fault ? 'kill' : 'throw',
      pointerDelayMs: process.env.POINTER_DELAY_MS ? Number(process.env.POINTER_DELAY_MS) : undefined,
      gate: gateAt
        ? {
            at: gateAt,
            readyPath: process.env.GATE_READY ?? '',
            waitPath: process.env.GATE_WAIT ?? '',
          }
        : undefined,
      mutation: {
        type: 'append-hist',
        cardId: process.env.CARD_ID ?? 'card-0',
        rating: Number(process.env.RATING ?? 3),
        reviewedAt: Number(process.env.REVIEWED_AT ?? Date.now()),
      },
    });
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } finally {
    await prisma.$disconnect();
  }
}

void main().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exit(1);
});
