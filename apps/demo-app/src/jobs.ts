import { Worker } from 'node:worker_threads';
import { scriptPath } from './compose';

export type WorkerEvent = { type: string; [key: string]: unknown };

export function signal(sab: SharedArrayBuffer): void {
  const flag = new Int32Array(sab);
  Atomics.store(flag, 0, 1);
  Atomics.notify(flag, 0);
}

export function startJob(job: object, timeoutMs = 60_000) {
  const worker = new Worker(scriptPath('reader-worker.js'));
  const events: WorkerEvent[] = [];
  let settled = false;
  const result = new Promise<WorkerEvent>((resolve, reject) => {
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      void worker.terminate();
      reject(new Error(`worker timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    worker.on('message', (message: WorkerEvent) => {
      if (message.type === 'result') {
        settled = true;
        clearTimeout(timer);
        resolve(message);
        return;
      }
      if (message.type === 'error') {
        settled = true;
        clearTimeout(timer);
        reject(new Error(String(message.message)));
        return;
      }
      events.push(message);
    });
    worker.on('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
  });
  worker.postMessage(job);
  return { worker, result, events };
}

export async function finishJob<T>(job: ReturnType<typeof startJob>): Promise<T> {
  try {
    return (await job.result) as T;
  } finally {
    await job.worker.terminate();
  }
}
