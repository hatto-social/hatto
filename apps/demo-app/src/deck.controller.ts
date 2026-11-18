import {
  ArgumentsHost,
  Body,
  Catch,
  Controller,
  ExceptionFilter,
  Get,
  Param,
  Post,
  Query,
} from '@nestjs/common';
import { CatalogService } from './catalog/catalog.service';
import { ForbiddenError } from './faults';
import { PublishService } from './publish/publish.service';
import { ReadService } from './read/read.service';

@Catch(ForbiddenError)
export class ForbiddenFilter implements ExceptionFilter {
  catch(exception: ForbiddenError, host: ArgumentsHost): void {
    const response = host.switchToHttp().getResponse<{
      status(code: number): { json(body: unknown): void };
    }>();
    response.status(403).json({ error: exception.message });
  }
}

@Controller()
export class DeckController {
  constructor(
    private readonly publish: PublishService,
    private readonly read: ReadService,
    private readonly catalog: CatalogService,
  ) {}

  @Get('health')
  health(): { ok: boolean; spike: boolean } {
    return { ok: true, spike: true };
  }

  @Post('decks')
  async create(@Body() body: { handle?: string; title?: string }) {
    if (!body.handle || !body.title) return { error: 'handle and title are required' };
    const root = process.env.DECK_ROOT ?? '/tmp/hatto-demo-decks';
    return this.publish.createDeck({ ownerHandle: body.handle, title: body.title, root });
  }

  @Post('decks/:id/cards')
  async addCard(
    @Param('id') id: string,
    @Body() body: { handle?: string; cardId?: string; front?: string; back?: string },
  ) {
    if (!body.handle || !body.cardId || body.front === undefined || body.back === undefined) {
      return { error: 'handle, cardId, front, and back are required' };
    }
    const user = await this.catalog.ensureUser(body.handle);
    const root = process.env.DECK_ROOT ?? '/tmp/hatto-demo-decks';
    return this.publish.publish({
      deckId: id,
      actorId: user.id,
      root,
      strategy: 'immutable',
      pathStyle: 'unique',
      processLock: true,
      advisoryLock: true,
      databaseUrl: process.env.DATABASE_URL,
      mutation: {
        type: 'add-cards',
        cards: [{ id: body.cardId, fields: { front: body.front, back: body.back } }],
      },
    });
  }

  @Get('decks/:id')
  async getDeck(@Param('id') id: string, @Query('handle') handle?: string) {
    if (!handle) return { error: 'handle is required' };
    const user = await this.catalog.ensureUser(handle);
    const view = await this.read.read({
      deckId: id,
      readerId: user.id,
      snapshot: 'tx',
      uriMode: 'ro-immutable',
      cache: 'versioned',
      pin: 'none',
    });
    return {
      version: view.manifest.version,
      hash: view.manifest.hash,
      cards: view.cards.length,
      hist: view.hist.length,
      skew: view.skew,
      mixed: view.mixed,
      cache: view.cache,
    };
  }
}
