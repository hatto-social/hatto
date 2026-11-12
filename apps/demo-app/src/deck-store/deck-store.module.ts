import { Module } from '@nestjs/common';
import { DeckStoreService } from './deck-store.service';
import { HandleLru } from './handle-lru';

@Module({
  providers: [
    {
      provide: HandleLru,
      useFactory: () => new HandleLru(Number(process.env.HANDLE_LRU_BYTES ?? 32 * 1024 * 1024)),
    },
    DeckStoreService,
  ],
  exports: [DeckStoreService, HandleLru],
})
export class DeckStoreModule {}
