import { Module } from '@nestjs/common';
import { CatalogModule } from './catalog/catalog.module';
import { DeckLock } from './deck-store/deck-lock';
import { DeckStoreModule } from './deck-store/deck-store.module';
import { GcService } from './gc/gc.service';
import { PrismaModule } from './prisma/prisma.module';
import { PublishService } from './publish/publish.service';
import { BodyCache } from './read/body-cache';
import { ReadService } from './read/read.service';
import { DeckController } from './deck.controller';

@Module({
  imports: [PrismaModule, DeckStoreModule, CatalogModule],
  controllers: [DeckController],
  providers: [DeckLock, BodyCache, PublishService, ReadService, GcService],
})
export class AppModule {}
