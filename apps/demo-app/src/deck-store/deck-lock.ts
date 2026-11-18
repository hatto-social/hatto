import { Injectable } from '@nestjs/common';

/** In-process queue. One writer at a time per deck, inside this process only. */
@Injectable()
export class DeckLock {
  private readonly tails = new Map<string, Promise<void>>();

  with<T>(deckId: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.tails.get(deckId) ?? Promise.resolve();
    const run = prev.then(fn, fn);
    this.tails.set(
      deckId,
      run.then(
        () => undefined,
        () => undefined,
      ),
    );
    return run;
  }
}
