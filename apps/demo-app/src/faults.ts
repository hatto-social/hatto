export type FaultPoint =
  | 'afterTempWrite'
  | 'beforeFsync'
  | 'afterFsync'
  | 'beforeRename'
  | 'afterRename'
  | 'beforePointerTx'
  | 'insidePointerTx'
  | 'afterPointerCommit';

export const FAULT_POINTS: FaultPoint[] = [
  'afterTempWrite',
  'beforeFsync',
  'afterFsync',
  'beforeRename',
  'afterRename',
  'beforePointerTx',
  'insidePointerTx',
  'afterPointerCommit',
];

export class FaultInjected extends Error {
  readonly point: FaultPoint;
  constructor(point: FaultPoint) {
    super(`fault:${point}`);
    this.name = 'FaultInjected';
    this.point = point;
  }
}

export class ForbiddenError extends Error {
  constructor(message = 'forbidden') {
    super(message);
    this.name = 'ForbiddenError';
  }
}

export class ConflictError extends Error {
  constructor(message = 'version conflict') {
    super(message);
    this.name = 'ConflictError';
  }
}

export class FileMissingError extends Error {
  constructor(message = 'version file missing before pointer commit') {
    super(message);
    this.name = 'FileMissingError';
  }
}

export class CorruptFileError extends Error {
  constructor(message = 'version file failed integrity check') {
    super(message);
    this.name = 'CorruptFileError';
  }
}

export interface Gate {
  at: FaultPoint;
  readyPath: string;
  waitPath: string;
  timeoutMs?: number;
}
