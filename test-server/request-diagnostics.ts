import { appendFileSync, mkdirSync, statSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';

type Endpoint = '/test/expiring-session' | '/auth/plugin/rownd/user' | '/auth/plugin/rownd/user/field' | '/auth/plugin/rownd/user/meta';
type Phase = 'request' | 'queue' | 'config' | 'user' | 'session' | 'session-info' | 'restore';
type CaptureState = 'not-captured' | 'pending' | 'completed' | 'superseded';
const traces = new WeakMap<ServerResponse, RequestDiagnostics>();
const active = new Set<RequestDiagnostics>();
let sequence = 0;

export function appendBoundedLine(file: string, line: string, maxBytes = 1024 * 1024) {
  mkdirSync(path.dirname(file), { recursive: true });
  const size = (() => {
    try { return statSync(file).size; } catch { return 0; }
  })();
  if (size + Buffer.byteLength(line) > maxBytes) return;
  appendFileSync(file, line);
}

export class RequestDiagnostics {
  private readonly id = `${process.pid}-${++sequence}`;
  private readonly started = performance.now();
  private currentPhase: Phase = 'request';
  private captureState: CaptureState = 'not-captured';
  private clientClosed = false;

  constructor(req: IncomingMessage, private readonly res: ServerResponse, private readonly endpoint: Endpoint) {
    this.log('request_start');
    const pending = setTimeout(() => this.log('request_pending'), 2_000);
    pending.unref();
    req.once('aborted', () => this.log('request_aborted'));
    res.once('finish', () => {
      clearTimeout(pending);
      this.log('response_finish');
      active.delete(this);
    });
    res.once('close', () => {
      clearTimeout(pending);
      this.clientClosed = true;
      this.log('response_close');
      active.delete(this);
    });
  }

  private log(event: string, phaseDurationMs?: number) {
    // Only fixed route names and lifecycle metadata. Never serialize req, errors,
    // headers, query strings, bodies, or the capturedRequests object.
    const line = JSON.stringify({
      time: new Date().toISOString(), requestId: this.id, endpoint: this.endpoint,
      method: this.endpoint === '/test/expiring-session' ? 'POST' : 'PUT',
      event, phase: this.currentPhase, durationMs: Math.round(performance.now() - this.started),
      phaseDurationMs, captureState: this.captureState, clientClosed: this.clientClosed,
      completed: this.res.writableFinished,
      statusCode: this.res.headersSent ? this.res.statusCode : undefined,
    });
    console.log(`[iOS harness request] ${line}`);
    const directory = process.env.IOS_E2E_DIAGNOSTICS_DIR;
    if (directory) {
      try { appendBoundedLine(path.join(directory, `requests-${process.pid}.ndjson`), `${line}\n`); }
      catch { console.error('[iOS harness diagnostics] Could not write request diagnostics'); }
    }
  }

  startPhase(phase: Phase) {
    this.currentPhase = phase;
    const started = performance.now();
    this.log('phase_start');
    return (succeeded = true) => {
      this.currentPhase = phase;
      this.log(succeeded ? 'phase_end' : 'phase_error', Math.round(performance.now() - started));
    };
  }

  async phase<T>(phase: Phase, operation: () => Promise<T>): Promise<T> {
    const finish = this.startPhase(phase);
    try {
      const result = await operation();
      finish();
      return result;
    } catch (error) {
      finish(false);
      throw error;
    }
  }

  captured(completed: boolean, current = true) {
    this.captureState = current ? (completed ? 'completed' : 'pending') : 'superseded';
    this.log('capture_updated');
  }

  snapshot() { this.log('reset_with_request_pending'); }
}

export function startRequestDiagnostics(req: IncomingMessage, res: ServerResponse, endpoint: Endpoint) {
  const trace = new RequestDiagnostics(req, res, endpoint);
  traces.set(res, trace);
  active.add(trace);
}

export function requestDiagnostics(res: ServerResponse) { return traces.get(res); }

export function snapshotPendingRequests() {
  for (const trace of active) trace.snapshot();
}
