import { CatalogService } from './catalog/catalog.service';
import { DeckLock } from './deck-store/deck-lock';
import { DeckStoreService } from './deck-store/deck-store.service';
import { HandleLru } from './deck-store/handle-lru';
import { GcService } from './gc/gc.service';
import { PrismaService } from './prisma/prisma.service';
import { PublishService } from './publish/publish.service';
import { BodyCache } from './read/body-cache';
import { ReadService } from './read/read.service';
import path from 'node:path';

export function compose(capBytes = 32 * 1024 * 1024) {
  const prisma = new PrismaService();
  const lru = new HandleLru(capBytes);
  const decks = new DeckStoreService(lru);
  const catalog = new CatalogService(prisma);
  const locks = new DeckLock();
  const publish = new PublishService(decks, catalog, locks);
  const read = new ReadService(decks, catalog, new BodyCache());
  const gc = new GcService(decks, catalog);
  return { prisma, lru, decks, catalog, locks, publish, read, gc };
}

export type Services = ReturnType<typeof compose>;

export function scriptPath(name: string): string {
  return path.join(__dirname, name);
}
