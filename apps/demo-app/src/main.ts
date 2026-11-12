import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { ForbiddenFilter } from './deck.controller';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);
  app.useGlobalFilters(new ForbiddenFilter());
  const port = Number(process.env.PORT ?? 3099);
  await app.listen(port);
}

void bootstrap();
