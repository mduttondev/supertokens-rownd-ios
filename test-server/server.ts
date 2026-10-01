import RowndMigrationPlugin, { setRowndClient } from '@supertokens-plugins/rownd-nodejs';
import cors from 'cors';
import express from 'express';
import type { Server } from 'http';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import SuperTokens from 'supertokens-node';
import { errorHandler, middleware } from 'supertokens-node/framework/express';
import AccountLinking from 'supertokens-node/recipe/accountlinking';
import EmailVerification from 'supertokens-node/recipe/emailverification';
import Multitenancy from 'supertokens-node/recipe/multitenancy';
import Passwordless from 'supertokens-node/recipe/passwordless';
import Session from 'supertokens-node/recipe/session';
import { verifySession } from 'supertokens-node/recipe/session/framework/express';
import ThirdParty from 'supertokens-node/recipe/thirdparty';
import UserMetadata from 'supertokens-node/recipe/usermetadata';
import { GenericContainer, Network, type StartedNetwork, type StartedTestContainer, Wait } from 'testcontainers';
import { containerStartupLogger, containerStartupTimeoutMs, logDockerDiagnostics } from './startup';

type HarnessCounters = {
  createSession: number;
  appleSignIn: number;
  googleSignIn: number;
  userGet: number;
  userUpdate: number;
  userFieldUpdate: number;
  userMetaUpdate: number;
  signOut: number;
  stRefresh: number;
  stRefreshWithCredentials: number;
  legacyRefresh: number;
  migrate: number;
  protected: number;
  refreshOnce: number;
  passwordlessCreate: number;
  passwordlessConsume: number;
  stSignOut: number;
};

type CapturedRequest = {
  authorization?: string;
  authorizationCount: number;
  rowndAppKey?: string;
  body?: unknown;
  field?: string;
  pendingVerificationId?: string;
  responseSessionHeaders?: {
    accessToken: boolean;
    refreshToken: boolean;
    frontToken: boolean;
  };
  statusCode?: number;
};

type CapturedVerificationEmail = {
  email: string;
  link: string;
  token: string;
};

type CapturedPasswordlessEmail = {
  email: string;
  urlWithLinkCode?: string;
  userInputCode?: string;
};

type MigrationMode = 'normal' | 'migrate401' | 'migrate409' | 'legacyRefreshFailure' | 'migrateWithoutRefreshHeader';

type IntegrationHarness = {
  apiUrl: string;
  stop: () => Promise<void>;
};

type RaceEvent = {
  order: number;
  name: string;
  statusCode?: number;
  sessionHandle?: string;
  reason?: string;
};

type HoldLifecycle = 'held' | 'released' | 'timed-out' | 'disconnected' | 'reset' | 'shutdown';
type ReleaseReason = 'manual' | 'timeout' | 'disconnect' | 'reset' | 'shutdown' | 'dependency-ready';

type ReleaseControl = {
  isActive: () => boolean;
  release: (reason: ReleaseReason) => boolean;
};

type StaleRefreshRace = {
  generation: number;
  armed: boolean;
  events: RaceEvent[];
  refreshCandidateReserved: boolean;
  heldRefresh?: {
    statusCode: number;
    sessionHandle?: string;
    lifecycle: HoldLifecycle;
    releaseReason?: ReleaseReason;
    responseFinished: boolean;
  };
  verificationWaiting: boolean;
  verificationStatusCode?: number;
  heldProfile?: {
    requestSessionHandle?: string;
    lifecycle: HoldLifecycle;
    releaseReason?: ReleaseReason;
    responseFinished: boolean;
    statusCode?: number;
  };
  postReleaseRefreshAttempts: number;
  postReleaseRefreshes: Array<{ statusCode: number; sessionHandle?: string }>;
  refreshControl?: ReleaseControl;
  verificationControl?: ReleaseControl;
  profileControl?: ReleaseControl;
};

const port = Number(process.env.IOS_HARNESS_PORT || 3100);
const appName = 'Rownd iOS Integration Tests';
const hubBaseUrl = process.env.IOS_HUB_BASE_URL || 'http://127.0.0.1:8788';
const hubHealthUrl = process.env.IOS_HUB_HEALTH_URL || `${hubBaseUrl}/health`;
const websiteDomain = process.env.IOS_WEBSITE_DOMAIN || new URL(hubBaseUrl).origin;
const appId = 'app_test_rownd_ios';
const appKey = 'test_app_key';
const rowndAppUserIdClaim = 'https://auth.rownd.io/app_user_id';
const accountLinkingTestLicense =
  'N2uEOdEzd1XZZ5VBSTGYaM7Ia4s8wAqRWFAxLqTYrB6GQ=' +
  'vssOLo3c=PkFgcExkaXs=IA-d9UWccoNKsyUgNhOhcKtM1bjC5OLrYRpTAgN-2EbKYsQGGQRQHuUN4EO1V';

let network: StartedNetwork | undefined;
let postgresContainer: StartedTestContainer | undefined;
let coreContainer: StartedTestContainer | undefined;
let server: Server | undefined;
let stopPromise: Promise<void> | undefined;

const counters: HarnessCounters = {
  createSession: 0,
  appleSignIn: 0,
  googleSignIn: 0,
  userGet: 0,
  userUpdate: 0,
  userFieldUpdate: 0,
  userMetaUpdate: 0,
  signOut: 0,
  stRefresh: 0,
  stRefreshWithCredentials: 0,
  legacyRefresh: 0,
  migrate: 0,
  protected: 0,
  refreshOnce: 0,
  passwordlessCreate: 0,
  passwordlessConsume: 0,
  stSignOut: 0,
};

const capturedRequests: Record<string, CapturedRequest | undefined> = {};
let latestVerificationEmail: CapturedVerificationEmail | undefined;
let latestPasswordlessEmail: CapturedPasswordlessEmail | undefined;
const passwordlessConsumeStatuses: number[] = [];
let migrationMode: MigrationMode = 'normal';
let refreshUnavailable = false;
let holdNextUserGet = false;
let holdAllUserGets = false;
const heldUserGetRequests = new Set<() => void>();
const raceTimeoutMs = 20_000;
let nextRaceGeneration = 1;
let staleRefreshRace: StaleRefreshRace = createStaleRefreshRace();

function createStaleRefreshRace(): StaleRefreshRace {
  return {
    generation: nextRaceGeneration++,
    armed: false,
    events: [],
    refreshCandidateReserved: false,
    verificationWaiting: false,
    postReleaseRefreshAttempts: 0,
    postReleaseRefreshes: [],
  };
}

function recordRaceEvent(
  race: StaleRefreshRace,
  name: string,
  metadata: Omit<RaceEvent, 'name' | 'order'> = {},
) {
  race.events.push({ order: race.events.length + 1, name, ...metadata });
}

function sessionHandleFromTokenHeader(value: string | string[] | number | undefined) {
  if (typeof value !== 'string') {
    return undefined;
  }
  const token = value.startsWith('Bearer ') ? value.slice('Bearer '.length) : value;
  const payload = token.split('.')[1];
  if (!payload) {
    return undefined;
  }
  try {
    const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString()) as Record<string, unknown>;
    return typeof decoded.sessionHandle === 'string' ? decoded.sessionHandle : undefined;
  } catch {
    return undefined;
  }
}

function createReleaseControl(
  race: StaleRefreshRace,
  timeoutName: string,
  onRelease: (reason: ReleaseReason) => void,
): ReleaseControl {
  let released = false;
  const timeout = setTimeout(() => {
    if (!released) {
      recordRaceEvent(race, timeoutName, { reason: 'timeout' });
      control.release('timeout');
    }
  }, raceTimeoutMs);
  const control: ReleaseControl = {
    isActive: () => !released,
    release: (reason) => {
      if (released) {
        return false;
      }
      released = true;
      clearTimeout(timeout);
      onRelease(reason);
      return true;
    },
  };
  return control;
}

function lifecycleForRelease(reason: ReleaseReason): HoldLifecycle {
  switch (reason) {
    case 'manual':
    case 'dependency-ready':
      return 'released';
    case 'timeout':
      return 'timed-out';
    case 'disconnect':
      return 'disconnected';
    case 'reset':
      return 'reset';
    case 'shutdown':
      return 'shutdown';
  }
}

function releaseStaleRefreshRace(race: StaleRefreshRace, reason: 'reset' | 'shutdown') {
  race.refreshControl?.release(reason);
  race.verificationControl?.release(reason);
  race.profileControl?.release(reason);
}

function restoreStaleRefreshRace(reason: 'reset' | 'shutdown' = 'reset') {
  const previousRace = staleRefreshRace;
  releaseStaleRefreshRace(previousRace, reason);
  staleRefreshRace = createStaleRefreshRace();
}

function staleRefreshRaceState() {
  const race = staleRefreshRace;
  return {
    status: 'OK',
    generation: race.generation,
    armed: race.armed,
    events: race.events,
    refreshCandidateReserved: race.refreshCandidateReserved,
    heldRefresh: race.heldRefresh,
    verificationWaiting: race.verificationWaiting,
    verificationStatusCode: race.verificationStatusCode,
    heldProfile: race.heldProfile,
    postReleaseRefreshAttempts: race.postReleaseRefreshAttempts,
    postReleaseRefreshes: race.postReleaseRefreshes,
  };
}

function observePostReleaseRefresh(race: StaleRefreshRace, res: express.Response) {
  race.postReleaseRefreshAttempts += 1;
  recordRaceEvent(race, 'post-release-refresh-attempted');
  res.on('finish', () => {
    const observation = {
      statusCode: res.statusCode,
      sessionHandle: sessionHandleFromTokenHeader(res.getHeader('st-access-token')),
    };
    race.postReleaseRefreshes.push(observation);
    recordRaceEvent(race, 'post-release-refresh-finished', observation);
  });
  res.on('close', () => {
    if (!res.writableFinished) {
      recordRaceEvent(race, 'post-release-refresh-disconnected', { reason: 'disconnect' });
    }
  });
}

function interceptStaleRefreshResponse(race: StaleRefreshRace, req: express.Request, res: express.Response) {
  const originalWrite = res.write.bind(res) as (...args: any[]) => boolean;
  const originalEnd = res.end.bind(res) as (...args: any[]) => express.Response;
  const writes: any[][] = [];
  let endArgs: any[] = [];
  let ended = false;
  let disconnected = false;

  const flush = () => {
    res.write = originalWrite as typeof res.write;
    res.end = originalEnd as typeof res.end;
    if (res.destroyed) {
      return;
    }
    for (const args of writes) {
      originalWrite(...args);
    }
    originalEnd(...endArgs);
  };

  const releaseForDisconnect = () => {
    disconnected = true;
    if (!res.writableFinished && race.refreshControl?.isActive()) {
      race.refreshControl.release('disconnect');
    }
  };
  req.on('aborted', releaseForDisconnect);
  res.on('close', releaseForDisconnect);
  res.on('finish', () => {
    if (race.heldRefresh) {
      race.heldRefresh.responseFinished = true;
      recordRaceEvent(race, 'refresh-response-finished', {
        statusCode: res.statusCode,
        sessionHandle: race.heldRefresh.sessionHandle,
      });
    } else {
      recordRaceEvent(race, 'refresh-candidate-response-finished', { statusCode: res.statusCode });
    }
  });

  res.write = ((...args: any[]) => {
    writes.push(args);
    return true;
  }) as typeof res.write;
  res.end = ((...args: any[]) => {
    if (ended) {
      return res;
    }
    ended = true;
    endArgs = args;

    if (res.statusCode < 200 || res.statusCode >= 300) {
      recordRaceEvent(race, 'refresh-candidate-not-successful', { statusCode: res.statusCode });
      flush();
      return res;
    }

    const sessionHandle = sessionHandleFromTokenHeader(res.getHeader('st-access-token'));
    race.heldRefresh = {
      statusCode: res.statusCode,
      sessionHandle,
      lifecycle: 'held',
      responseFinished: false,
    };
    recordRaceEvent(race, 'refresh-response-held', { statusCode: res.statusCode, sessionHandle });
    race.refreshControl = createReleaseControl(race, 'refresh-hold-timeout', (reason) => {
      if (race.heldRefresh) {
        race.heldRefresh.lifecycle = lifecycleForRelease(reason);
        race.heldRefresh.releaseReason = reason;
      }
      recordRaceEvent(race, 'refresh-response-released', { reason, statusCode: res.statusCode, sessionHandle });
      flush();
    });
    if (disconnected) {
      race.refreshControl.release('disconnect');
    }
    race.verificationControl?.release('dependency-ready');
    return res;
  }) as typeof res.end;
}

function observeRaceRefreshRequest(req: express.Request, res: express.Response) {
  const race = staleRefreshRace;
  if (!race.armed) {
    return;
  }
  if (!race.refreshCandidateReserved) {
    race.refreshCandidateReserved = true;
    recordRaceEvent(race, 'refresh-candidate-reserved');
    interceptStaleRefreshResponse(race, req, res);
    return;
  }
  if (race.heldRefresh?.lifecycle === 'released' && race.heldRefresh.releaseReason === 'manual') {
    observePostReleaseRefresh(race, res);
  }
}

function userGetBehaviorState() {
  return {
    behavior:
      heldUserGetRequests.size > 0 ? 'holding' : holdAllUserGets ? 'hold-all' : holdNextUserGet ? 'hold-next' : 'normal',
    heldRequestCount: heldUserGetRequests.size,
  };
}

function restoreUserGetBehavior() {
  holdNextUserGet = false;
  holdAllUserGets = false;
  for (const release of heldUserGetRequests) {
    release();
  }
  heldUserGetRequests.clear();
}

function captureRequest(name: string, req: express.Request) {
  const capturedRequest: CapturedRequest = {
    authorization: req.header('authorization'),
    authorizationCount: req.rawHeaders.filter((header) => header.toLowerCase() === 'authorization').length,
    rowndAppKey: req.header('x-rownd-app-key'),
  };
  capturedRequests[name] = capturedRequest;
  return capturedRequest;
}

function capturePluginRequest(name: string, req: express.Request, res: express.Response) {
  const capturedRequest: CapturedRequest = {
    ...captureRequest(name, req),
    body: req.body,
    field: typeof req.query.field === 'string' ? req.query.field : undefined,
    pendingVerificationId:
      typeof req.query.rowndPendingVerificationId === 'string' ? req.query.rowndPendingVerificationId : undefined,
  };
  capturedRequests[name] = capturedRequest;
  res.on('finish', () => {
    if (capturedRequests[name] !== capturedRequest) {
      return;
    }
    capturedRequests[name] = {
      ...capturedRequest,
      responseSessionHeaders: {
        accessToken: res.getHeader('st-access-token') !== undefined,
        refreshToken: res.getHeader('st-refresh-token') !== undefined,
        frontToken: res.getHeader('front-token') !== undefined,
      },
      statusCode: res.statusCode,
    };
  });
}

function resetCounters() {
  restoreStaleRefreshRace();
  counters.createSession = 0;
  counters.appleSignIn = 0;
  counters.googleSignIn = 0;
  counters.userGet = 0;
  counters.userUpdate = 0;
  counters.userFieldUpdate = 0;
  counters.userMetaUpdate = 0;
  counters.signOut = 0;
  counters.stRefresh = 0;
  counters.stRefreshWithCredentials = 0;
  counters.legacyRefresh = 0;
  counters.migrate = 0;
  counters.protected = 0;
  counters.refreshOnce = 0;
  counters.passwordlessCreate = 0;
  counters.passwordlessConsume = 0;
  counters.stSignOut = 0;

  for (const key of Object.keys(capturedRequests)) {
    delete capturedRequests[key];
  }

  latestVerificationEmail = undefined;
  latestPasswordlessEmail = undefined;
  passwordlessConsumeStatuses.length = 0;
  migrationMode = 'normal';
  refreshUnavailable = false;
  restoreUserGetBehavior();
}

function createLegacyAccessToken(userId: string) {
  const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return [
    encode({ alg: 'none', typ: 'JWT' }),
    encode({
      sub: userId,
      exp: Math.floor(Date.now() / 1000) + 3_600,
      [rowndAppUserIdClaim]: userId,
    }),
    'signature',
  ].join('.');
}

export async function startIntegrationHarness(): Promise<IntegrationHarness> {
  try {
    return await createIntegrationHarness();
  } catch (error) {
    console.error('[iOS harness] Startup failed before cleanup', error);
    await logDockerDiagnostics();
    await stopIntegrationHarness();
    throw error;
  }
}

async function createIntegrationHarness(): Promise<IntegrationHarness> {
  const startupStarted = Date.now();
  const readinessTimeoutMs = containerStartupTimeoutMs();
  const logStage = (stage: string) => console.log(`[iOS harness +${((Date.now() - startupStarted) / 1000).toFixed(1)}s] ${stage}`);
  resetCounters();
  const { privateKey: applePrivateKey } = generateKeyPairSync('ec', {
    namedCurve: 'P-256',
  });
  const testApplePrivateKey = applePrivateKey.export({ type: 'sec1', format: 'pem' }).toString();

  logStage('Creating Docker network (including Testcontainers runtime/reaper initialization)');
  network = await new Network().start();
  logStage('Docker network ready; pulling/starting Postgres');
  const postgresLogs = containerStartupLogger('Postgres');
  postgresContainer = await new GenericContainer('postgres:14')
    .withNetwork(network)
    .withNetworkAliases('postgres')
    .withEnvironment({
      POSTGRES_USER: 'supertokens',
      POSTGRES_PASSWORD: 'somepassword',
      POSTGRES_DB: 'supertokens',
    })
    .withExposedPorts(5432)
    // The entrypoint's temporary initialization server emits the same message first.
    .withWaitStrategy(Wait.forLogMessage('database system is ready to accept connections', 2))
    .withStartupTimeout(readinessTimeoutMs)
    .withLogConsumer(postgresLogs.consume)
    .start();
  postgresLogs.stop();

  const coreImage = process.env.E2E_CORE_IMAGE || 'supertokens/supertokens-postgresql:12.0.10';
  logStage(`Postgres ready; pulling/starting SuperTokens Core (readiness budget ${readinessTimeoutMs / 1000}s, excluding image pull)`);
  const coreLogs = containerStartupLogger('Core');
  coreContainer = await new GenericContainer(coreImage)
    .withNetwork(network)
    .withEnvironment({
      POSTGRESQL_CONNECTION_URI: 'postgresql://supertokens:somepassword@postgres:5432/supertokens',
      ACCESS_TOKEN_VALIDITY: '3600',
      REFRESH_TOKEN_VALIDITY: '144000',
    })
    .withExposedPorts(3567)
    .withWaitStrategy(Wait.forHttp('/hello', 3567, { abortOnContainerExit: true }))
    .withStartupTimeout(readinessTimeoutMs)
    .withLogConsumer(coreLogs.consume)
    .start();
  coreLogs.stop();

  logStage('SuperTokens Core ready; enabling harness features');
  const coreBaseURI = `http://${coreContainer.getHost()}:${coreContainer.getMappedPort(3567)}`;
  const baseLicenseResponse = await fetch(`${coreBaseURI}/ee/license`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ licenseKey: accountLinkingTestLicense }),
  });
  if (!baseLicenseResponse.ok) {
    throw new Error(`Failed to enable harness features: ${baseLicenseResponse.status} ${await baseLicenseResponse.text()}`);
  }
  // A named app allows the expiry fixture to change its lifetime via Core's API;
  // the default app's base configuration is immutable at runtime.
  const coreAppId = 'rownd-ios-harness';
  logStage('Creating Core harness app');
  const appResponse = await fetch(`${coreBaseURI}/recipe/multitenancy/app/v2`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json', 'cdi-version': '5.3' },
    body: JSON.stringify({ appId: coreAppId }),
  });
  if (!appResponse.ok) {
    throw new Error(`Failed to create harness app: ${appResponse.status} ${await appResponse.text()}`);
  }
  const coreConnectionURI = `${coreBaseURI}/appid-${coreAppId}`;
  logStage('Enabling account linking for harness app');
  const licenseResponse = await fetch(`${coreConnectionURI}/ee/license`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ licenseKey: accountLinkingTestLicense }),
  });
  if (!licenseResponse.ok) {
    throw new Error(`Failed to enable account linking: ${licenseResponse.status} ${await licenseResponse.text()}`);
  }

  const app = express();
  logStage('Core configuration complete; starting harness HTTP server');

  const started = await new Promise<{ server: Server; port: number }>((resolve, reject) => {
    const listeningServer = app.listen(port, '127.0.0.1', () => {
      listeningServer.removeListener('error', reject);
      const address = listeningServer.address();

      if (!address || typeof address === 'string') {
        reject(new Error('Could not determine iOS integration harness port'));
        return;
      }

      resolve({ server: listeningServer, port: address.port });
    });
    listeningServer.once('error', reject);
  });

  server = started.server;
  const apiUrl = `http://127.0.0.1:${started.port}`;

  logStage('HTTP server listening; initializing SDK and routes');
  SuperTokens.init({
    supertokens: {
      connectionURI: coreConnectionURI,
    },
    appInfo: {
      appName,
      apiDomain: apiUrl,
      websiteDomain,
    },
    recipeList: [
      AccountLinking.init({
        shouldDoAutomaticAccountLinking: async () => ({
          shouldAutomaticallyLink: false,
          shouldRequireVerification: false,
        }),
      }),
      Session.init(),
      UserMetadata.init(),
      ThirdParty.init({
        signInAndUpFeature: {
          providers: [
            {
              config: {
                thirdPartyId: 'google',
                clients: [
                  {
                    clientId: 'test-google-client-id',
                    clientSecret: 'test-google-client-secret',
                  },
                ],
              },
            },
            {
              config: {
                thirdPartyId: 'apple',
                clients: [
                  {
                    clientId: 'test-apple-client-id',
                    additionalConfig: {
                      teamId: 'TESTTEAM01',
                      keyId: 'TESTKEY0001',
                      privateKey: testApplePrivateKey,
                    },
                  },
                ],
              },
            },
          ],
        },
      }),
      Passwordless.init({
        contactMethod: 'EMAIL_OR_PHONE',
        flowType: 'USER_INPUT_CODE_AND_MAGIC_LINK',
        emailDelivery: {
          service: {
            sendEmail: async (input) => {
              latestPasswordlessEmail = {
                email: input.email,
                urlWithLinkCode: input.urlWithLinkCode?.replace('/auth/verify', '/account/login'),
                userInputCode: input.userInputCode,
              };
            },
          },
        },
        smsDelivery: { service: { sendSms: async () => {} } },
      }),
      EmailVerification.init({
        mode: 'OPTIONAL',
        emailDelivery: {
          service: {
            sendEmail: async (input) => {
              const link = new URL(input.emailVerifyLink);
              const token = link.searchParams.get('token');
              if (!token) {
                throw new Error('Email verification link did not contain a token');
              }

              latestVerificationEmail = {
                email: input.user.email,
                link: input.emailVerifyLink,
                token,
              };
            },
          },
        },
      }),
    ],
    experimental: {
      plugins: [
        RowndMigrationPlugin.init({
          rowndAppKey: appKey,
          rowndAppSecret: 'rownd-e2e-secret-rownd-e2e-secret',
          schema: {
            first_name: {
              display_name: 'First name',
              type: 'string',
              owned_by: 'user',
              user_visible: true,
            },
            email: {
              display_name: 'Email',
              type: 'string',
              owned_by: 'user',
              user_visible: true,
            },
          },
          appConfig: {
            id: appId,
            name: appName,
            auth: {
              useExplicitSignUpFlow: true,
            },
            userVerificationFields: ['email'],
            signInMethods: [
              { method: 'google', iosClientId: 'test-google-ios-client-id' },
              { method: 'apple', iosClientType: 'native-apple-client' },
              { method: 'phone' },
              { method: 'email' },
              { method: 'anonymous' },
            ],
            profile: {
              accountInformation: {
                methods: {
                  email: { enabled: true },
                },
              },
            },
          },
        }),
      ],
    },
  });

  setRowndClient({
    validateToken: async () => ({ user_id: 'ios-test-user' }),
    fetchUserInfo: async ({ user_id }: { user_id: string }) =>
      ({
        state: 'enabled',
        auth_level: 'verified',
        data: { user_id, email: `${user_id}@example.com` },
        verified_data: { email: `${user_id}@example.com` },
        groups: [],
        meta: {},
      }) as any,
  });

  app.use(
    cors({
      origin: websiteDomain,
      allowedHeaders: ['content-type', 'x-rownd-app-key', ...SuperTokens.getAllCORSHeaders()],
      exposedHeaders: ['front-token', 'st-access-token', 'st-refresh-token', 'anti-csrf'],
      credentials: true,
    }),
  );
  app.use(express.json());
  app.use((req, res, next) => {
    if (req.method === 'POST' && req.path === '/auth/signinup/code') {
      counters.passwordlessCreate += 1;
    }
    if (req.method === 'POST' && req.path === '/auth/signinup/code/consume') {
      counters.passwordlessConsume += 1;
      res.on('finish', () => passwordlessConsumeStatuses.push(res.statusCode));
    }
    if (req.method === 'POST' && req.path === '/auth/signout') {
      counters.stSignOut += 1;
    }
    if (req.method === 'POST' && req.path === '/auth/session/refresh') {
      counters.stRefresh += 1;
      if (req.headers.authorization || /(?:^|;\s*)sRefreshToken=[^;]+/.test(req.headers.cookie || '')) {
        counters.stRefreshWithCredentials += 1;
      }
      observeRaceRefreshRequest(req, res);
      if (refreshUnavailable) {
        res.status(503).json({ status: 'ERROR', message: 'Temporary refresh outage' });
        return;
      }
    }
    if (req.method === 'POST' && req.path === '/auth/plugin/rownd/migrate') {
      counters.migrate += 1;
    }
    if (req.method === 'POST' && req.path === '/auth/plugin/rownd/signout') {
      counters.signOut += 1;
    }
    if (req.method === 'GET' && req.path === '/auth/plugin/rownd/user') {
      counters.userGet += 1;
      capturePluginRequest('userGet', req, res);
      const race = staleRefreshRace;
      if (race.armed && race.verificationStatusCode === 200 && !race.heldProfile) {
        const requestSessionHandle = sessionHandleFromTokenHeader(req.header('authorization'));
        const heldProfile: NonNullable<StaleRefreshRace['heldProfile']> = {
          requestSessionHandle,
          lifecycle: 'held' as HoldLifecycle,
          responseFinished: false,
        };
        race.heldProfile = heldProfile;
        recordRaceEvent(race, 'replacement-profile-held', { sessionHandle: requestSessionHandle });
        let disconnected = false;
        const releaseForDisconnect = () => {
          disconnected = true;
          race.profileControl?.release('disconnect');
        };
        req.on('aborted', releaseForDisconnect);
        res.on('close', () => {
          if (!res.writableFinished) {
            releaseForDisconnect();
          }
        });
        res.on('finish', () => {
          heldProfile.responseFinished = true;
          heldProfile.statusCode = res.statusCode;
          recordRaceEvent(race, 'replacement-profile-response-finished', {
            statusCode: res.statusCode,
            sessionHandle: requestSessionHandle,
          });
        });
        race.profileControl = createReleaseControl(race, 'profile-hold-timeout', (reason) => {
          heldProfile.lifecycle = lifecycleForRelease(reason);
          heldProfile.releaseReason = reason;
          recordRaceEvent(race, 'replacement-profile-released', {
            reason,
            sessionHandle: requestSessionHandle,
          });
          if (!disconnected && !res.destroyed) {
            next();
          }
        });
        return;
      }
      if (holdNextUserGet || holdAllUserGets) {
        holdNextUserGet = false;
        let releaseRequest!: () => void;
        const releasePromise = new Promise<void>((resolve) => {
          releaseRequest = resolve;
        });
        heldUserGetRequests.add(releaseRequest);
        void releasePromise.then(() => {
          heldUserGetRequests.delete(releaseRequest);
          next();
        });
        return;
      }
    }
    if (req.method === 'PUT' && req.path === '/auth/plugin/rownd/user') {
      counters.userUpdate += 1;
      capturePluginRequest('userUpdate', req, res);
    }
    if (req.method === 'PUT' && req.path === '/auth/plugin/rownd/user/field') {
      counters.userFieldUpdate += 1;
      capturePluginRequest('userFieldUpdate', req, res);
    }
    if (req.method === 'PUT' && req.path === '/auth/plugin/rownd/user/meta') {
      counters.userMetaUpdate += 1;
      capturePluginRequest('userMetaUpdate', req, res);
    }
    if (req.method === 'POST' && req.path === '/auth/user/email/verify') {
      capturePluginRequest('emailVerify', req, res);
      const race = staleRefreshRace;
      if (race.armed) {
        res.on('finish', () => {
          race.verificationStatusCode = res.statusCode;
          recordRaceEvent(race, 'verification-finished', {
            statusCode: res.statusCode,
            sessionHandle: sessionHandleFromTokenHeader(res.getHeader('st-access-token')),
          });
        });
      }
      if (race.armed && !race.heldRefresh) {
        if (race.verificationWaiting) {
          res.status(409).json({ status: 'ERROR', message: 'A verification request is already waiting' });
          return;
        }
        race.verificationWaiting = true;
        recordRaceEvent(race, 'verification-waiting-for-refresh');
        let disconnected = false;
        const releaseForDisconnect = () => {
          disconnected = true;
          race.verificationControl?.release('disconnect');
        };
        req.on('aborted', releaseForDisconnect);
        res.on('close', () => {
          if (!res.writableFinished) {
            releaseForDisconnect();
          }
        });
        race.verificationControl = createReleaseControl(
          race,
          'verification-wait-timeout',
          (reason) => {
            race.verificationWaiting = false;
            recordRaceEvent(race, 'verification-proceeded', { reason });
            if (!disconnected && !res.destroyed) {
              next();
            }
          },
        );
        return;
      }
      if (race.armed) {
        recordRaceEvent(race, 'verification-proceeded', { reason: 'dependency-ready' });
      }
    }

    next();
  });

  app.post('/test/migration-mode', (req, res) => {
    const mode = req.body?.mode;
    if (!['normal', 'migrate401', 'migrate409', 'legacyRefreshFailure', 'migrateWithoutRefreshHeader'].includes(mode)) {
      res.status(400).json({ status: 'ERROR', message: 'Invalid migration mode' });
      return;
    }

    migrationMode = mode;
    res.json({ status: 'OK', mode: migrationMode });
  });

  app.get('/test/stale-refresh-race', (_req, res) => {
    res.json(staleRefreshRaceState());
  });

  app.post('/test/stale-refresh-race', (req, res) => {
    const action = req.body?.action;
    if (action === 'arm') {
      restoreStaleRefreshRace();
      const race = staleRefreshRace;
      race.armed = true;
      recordRaceEvent(race, 'armed');
    } else if (action === 'release-stale-refresh') {
      const race = staleRefreshRace;
      if (
        race.heldRefresh?.lifecycle !== 'held' ||
        !race.refreshControl?.isActive() ||
        race.heldProfile?.lifecycle !== 'held'
      ) {
        res.status(409).json({
          ...staleRefreshRaceState(),
          status: 'ERROR',
          message: 'Active refresh and replacement profile holds are required before stale release',
        });
        return;
      }
      recordRaceEvent(race, 'stale-refresh-released', {
        reason: 'manual',
        statusCode: race.heldRefresh.statusCode,
        sessionHandle: race.heldRefresh.sessionHandle,
      });
      race.refreshControl.release('manual');
    } else if (action === 'release-profile') {
      const race = staleRefreshRace;
      if (race.heldProfile?.lifecycle !== 'held' || !race.profileControl?.isActive()) {
        res.status(409).json({
          ...staleRefreshRaceState(),
          status: 'ERROR',
          message: 'No active replacement profile request is held',
        });
        return;
      }
      race.profileControl.release('manual');
    } else if (action === 'reset') {
      restoreStaleRefreshRace();
    } else {
      res.status(400).json({ status: 'ERROR', message: 'Invalid stale refresh race action' });
      return;
    }

    res.json(staleRefreshRaceState());
  });

  app.get('/test/user-get-behavior', (_req, res) => {
    res.json({ status: 'OK', ...userGetBehaviorState() });
  });

  app.post('/test/user-get-behavior', (req, res) => {
    const behavior = req.body?.behavior;
    if (behavior === 'hold-next') {
      if (holdNextUserGet || holdAllUserGets || heldUserGetRequests.size > 0) {
        res.status(409).json({ status: 'ERROR', message: 'A user GET is already armed or held' });
        return;
      }
      holdNextUserGet = true;
    } else if (behavior === 'hold-all') {
      if (holdNextUserGet || holdAllUserGets || heldUserGetRequests.size > 0) {
        res.status(409).json({ status: 'ERROR', message: 'A user GET is already armed or held' });
        return;
      }
      holdAllUserGets = true;
    } else if (behavior === 'normal') {
      restoreUserGetBehavior();
    } else {
      res.status(400).json({ status: 'ERROR', message: 'Invalid user GET behavior' });
      return;
    }

    res.json({ status: 'OK', ...userGetBehaviorState() });
  });

  app.post('/auth/plugin/rownd/migrate', (req, res, next) => {
    captureRequest('migrate', req);

    if (migrationMode === 'migrate401') {
      res.status(401).json({ status: 'ERROR', message: 'Legacy Rownd token rejected' });
      return;
    }

    if (migrationMode === 'migrate409') {
      res.status(409).json({ status: 'ERROR', message: 'User already migrated' });
      return;
    }

    if (migrationMode === 'migrateWithoutRefreshHeader') {
      const originalSetHeader = res.setHeader.bind(res);
      res.setHeader = (name: string, value: number | string | readonly string[]) => {
        if (name.toLowerCase() === 'st-refresh-token') {
          return res;
        }

        return originalSetHeader(name, value);
      };
    }

    next();
  });

  app.post('/auth/signinup', async (req: any, res: any, next) => {
    if (
      req.body?.thirdPartyId === 'apple' &&
      req.body?.redirectURIInfo?.redirectURIQueryParams?.code === 'fake-apple-auth-code'
    ) {
      counters.appleSignIn += 1;
      capturedRequests.appleSignIn = {
        ...captureRequest('appleSignIn', req),
        body: req.body,
      };

      const thirdPartyUserId = `ios-apple-user-${randomUUID()}`;
      const user = await ThirdParty.manuallyCreateOrUpdateUser(
        'public',
        'apple',
        thirdPartyUserId,
        `${thirdPartyUserId}@example.com`,
        true,
      );
      if (user.status !== 'OK') {
        res.status(500).json(user);
        return;
      }

      await Session.createNewSession(req, res, 'public', user.recipeUserId, {}, {}, {});
      res.json({ status: 'OK', createdNewRecipeUser: user.createdNewRecipeUser });
      return;
    }

    if (req.body?.thirdPartyId !== 'google' || req.body?.oAuthTokens?.id_token !== 'fake-google-id-token') {
      next();
      return;
    }

    counters.googleSignIn += 1;
    capturedRequests.googleSignIn = {
      ...captureRequest('googleSignIn', req),
      body: req.body,
    };

    const thirdPartyUserId = `ios-google-user-${randomUUID()}`;
    const user = await ThirdParty.manuallyCreateOrUpdateUser(
      'public',
      'google',
      thirdPartyUserId,
      `${thirdPartyUserId}@example.com`,
      true,
    );
    if (user.status !== 'OK') {
      res.status(500).json(user);
      return;
    }

    await Session.createNewSession(req, res, 'public', user.recipeUserId, {}, {}, {});
    res.json({ status: 'OK', createdNewRecipeUser: user.createdNewRecipeUser });
  });

  app.post('/auth/plugin/rownd/signout', verifySession(), (req, res) => {
    captureRequest('signOut', req);
    res.json({ status: 'OK' });
  });

  app.use(middleware());

  app.post('/hub/auth/token', (_req, res) => {
    counters.legacyRefresh += 1;

    if (migrationMode === 'legacyRefreshFailure') {
      res.status(401).json({ status: 'ERROR', message: 'Legacy refresh failed' });
      return;
    }

    res.json({
      access_token: 'legacy-refreshed-access-token',
      refresh_token: 'legacy-refreshed-refresh-token',
      is_verified_user: true,
    });
  });

  app.get('/health', (_req, res) => {
    res.json({ status: 'OK' });
  });

  app.get('/config', (_req, res) => {
    res.json({
      apiUrl,
      appId,
      appKey,
      hubBaseUrl,
      hubHealthUrl,
      supertokens: {
        appInfo: {
          apiDomain: apiUrl,
          apiBasePath: '/auth',
        },
      },
    });
  });

  app.post('/reset', (_req, res) => {
    resetCounters();
    res.json({ status: 'OK' });
  });

  app.get('/counters', (_req, res) => {
    res.json(counters);
  });

  app.get('/captured-requests', (_req, res) => {
    res.json(capturedRequests);
  });

  app.get('/test/email-verification/latest', (_req, res) => {
    if (!latestVerificationEmail) {
      res.json({ status: 'PENDING' });
      return;
    }

    res.json({ status: 'OK', ...latestVerificationEmail });
  });

  app.get('/test/passwordless/latest', (_req, res) => {
    if (!latestPasswordlessEmail) {
      res.json({ status: 'PENDING' });
      return;
    }

    res.json({ status: 'OK', ...latestPasswordlessEmail });
  });

  app.get('/test/passwordless/consumes', (_req, res) => {
    res.json({ count: counters.passwordlessConsume, statuses: passwordlessConsumeStatuses });
  });

  app.get('/test/passwordless/consumes/settled', async (_req, res) => {
    const initialCount = counters.passwordlessConsume;
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    res.json({
      count: counters.passwordlessConsume,
      changedDuringObservation: counters.passwordlessConsume !== initialCount,
      statuses: passwordlessConsumeStatuses,
    });
  });

  app.post('/test/existing-passwordless-user', async (req, res) => {
    const email = req.body?.email;
    if (typeof email !== 'string' || email.length === 0) {
      res.status(400).json({ status: 'ERROR', message: 'email is required' });
      return;
    }

    const signInResult = await Passwordless.signInUp({
      email,
      tenantId: 'public',
    });
    const userId = signInResult.user.id;
    const sessionHandles = await Session.getAllSessionHandlesForUser(userId, true);
    if (sessionHandles.length > 0) {
      res.status(500).json({
        status: 'ERROR',
        message: 'Existing passwordless fixture unexpectedly has a session',
      });
      return;
    }

    res.json({
      status: 'OK',
      email,
      userId,
      sessionHandleCount: sessionHandles.length,
    });
  });

  app.post('/test/legacy-session', async (_req, res) => {
    const email = `ios-legacy-${randomUUID()}@example.com`;
    const signInResult = await Passwordless.signInUp({
      email,
      tenantId: 'public',
    });
    const userId = signInResult.user.id;
    const sessionHandles = await Session.getAllSessionHandlesForUser(signInResult.user.id, true);
    if (sessionHandles.length > 0) {
      res.status(500).json({ status: 'ERROR', message: 'Legacy fixture user unexpectedly has a session' });
      return;
    }

    res.json({
      status: 'OK',
      userId,
      email,
      accessToken: createLegacyAccessToken(userId),
      refreshToken: `legacy-refresh-${randomUUID()}`,
      sessionHandleCount: sessionHandles.length,
    });
  });

  app.post('/test/unmigrated-legacy-session', async (_req, res) => {
    const userId = 'ios-test-user';
    await Session.revokeAllSessionsForUser(userId, true);
    const sessionHandles = await Session.getAllSessionHandlesForUser(userId, true);

    res.json({
      status: 'OK',
      userId,
      accessToken: createLegacyAccessToken(userId),
      refreshToken: `legacy-refresh-${randomUUID()}`,
      sessionHandleCount: sessionHandles.length,
    });
  });

  app.post('/test/profile-session', async (req: any, res: any) => {
    counters.createSession += 1;
    const email = req.body?.email;
    const firstName = req.body?.firstName;
    if (typeof email !== 'string' || typeof firstName !== 'string') {
      res.status(400).json({ status: 'ERROR', message: 'email and firstName are required' });
      return;
    }

    const signInResult = await Passwordless.signInUp({
      email,
      tenantId: 'public',
    });
    await UserMetadata.updateUserMetadata(signInResult.user.id, {
      first_name: firstName,
    });
    await Session.createNewSession(req, res, 'public', signInResult.recipeUserId, {}, {}, {});
    res.json({ status: 'OK', userId: signInResult.user.id });
  });

  app.post('/test/session', async (req: any, res: any) => {
    counters.createSession += 1;
    const requestedUserId = typeof req.body?.userId === 'string' ? req.body.userId : 'ios-test-user';
    const user = await Passwordless.signInUp({
      email: `${requestedUserId}@example.com`,
      tenantId: 'public',
    });

    await Session.createNewSession(req, res, 'public', user.recipeUserId, {}, {}, {});
    res.json({ status: 'OK', userId: user.user.id });
  });

  // Issue a genuinely short-lived Core token, then restore the normal lifetime
  // before refreshing. This avoids changing device time or forging expired JWTs.
  app.post('/test/expiring-session', async (req, res) => {
    const tenantId = 'public';
    const accessTokenValidity = req.body?.accessTokenValidity ?? 5;
    if (![5, 30, 90].includes(accessTokenValidity)) {
      res.status(400).json({ status: 'ERROR', message: 'accessTokenValidity must be 5, 30, or 90 seconds' });
      return;
    }
    await Multitenancy.createOrUpdateTenant(tenantId, {
      coreConfig: { access_token_validity: accessTokenValidity, refresh_token_validity: 144000 },
    });
    let fixture;
    try {
      const user = await Passwordless.signInUp({
        email: `ios-expiry-${randomUUID()}@example.com`,
        tenantId,
      });
      const session = await Session.createNewSession(req, res, tenantId, user.recipeUserId);
      counters.createSession += 1;
      const info = await Session.getSessionInformation(session.getHandle());
      fixture = { status: 'OK', userId: user.user.id, sessionHandle: session.getHandle(), info };
    } finally {
      await Multitenancy.createOrUpdateTenant(tenantId, {
        coreConfig: { access_token_validity: 3600, refresh_token_validity: 144000 },
      });
    }
    res.json(fixture);
  });

  app.post('/test/refresh-availability', (req, res) => {
    if (typeof req.body?.unavailable !== 'boolean') {
      res.status(400).json({ status: 'ERROR', message: 'unavailable must be a boolean' });
      return;
    }
    refreshUnavailable = req.body.unavailable;
    res.json({ status: 'OK' });
  });

  app.post('/test/revoke-session', async (req, res) => {
    if (typeof req.body?.sessionHandle !== 'string') {
      res.status(400).json({ status: 'ERROR', message: 'sessionHandle is required' });
      return;
    }
    await Session.revokeSession(req.body.sessionHandle);
    res.json({ status: 'OK' });
  });

  app.get('/test/protected', verifySession(), async (req: any, res) => {
    counters.protected += 1;
    captureRequest('protected', req);
    res.json({
      status: 'OK',
      userId: req.session.getUserId(),
      accessTokenPayload: req.session.getAccessTokenPayload(),
    });
  });

  app.get('/test/account', verifySession(), async (req: any, res) => {
    const user = await SuperTokens.getUser(req.session.getUserId());
    if (!user) {
      res.status(404).json({ status: 'ERROR', message: 'User not found' });
      return;
    }

    res.json({
      status: 'OK',
      userId: user.id,
      isPrimaryUser: user.isPrimaryUser,
      sessionHandle: req.session.getHandle(),
      sessionHandles: await Session.getAllSessionHandlesForUser(user.id, true),
      loginMethods: user.loginMethods.map((method) => ({
        recipeId: method.recipeId,
        recipeUserId: method.recipeUserId.getAsString(),
        email: method.email,
        verified: method.verified,
        thirdPartyId: method.thirdParty?.id,
        thirdPartyUserId: method.thirdParty?.userId,
      })),
    });
  });

  app.get(
    '/test/refresh-once',
    (req, res, next) => {
      counters.refreshOnce += 1;
      if (counters.refreshOnce === 1) {
        res.status(401).json({ status: 'UNAUTHORISED' });
        return;
      }

      next();
    },
    verifySession(),
    async (req: any, res) => {
      captureRequest('refreshOnce', req);
      res.json({
        status: 'OK',
        userId: req.session.getUserId(),
      });
    },
  );

  app.use(errorHandler());

  return {
    apiUrl,
    stop: stopIntegrationHarness,
  };
}

function stopIntegrationHarness() {
  if (stopPromise) {
    return stopPromise;
  }

  stopPromise = stopIntegrationHarnessResources();
  return stopPromise;
}

async function stopIntegrationHarnessResources() {
  const errors: unknown[] = [];
  restoreStaleRefreshRace('shutdown');
  restoreUserGetBehavior();
  const serverToStop = server;
  const coreToStop = coreContainer;
  const postgresToStop = postgresContainer;
  const networkToStop = network;
  server = undefined;
  coreContainer = undefined;
  postgresContainer = undefined;
  network = undefined;

  await stopResource('HTTP server', errors, async () => {
    if (!serverToStop) {
      return;
    }
    await new Promise<void>((resolve, reject) => {
      serverToStop.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  });
  await stopResource('SuperTokens Core', errors, () => coreToStop?.stop());
  await stopResource('Postgres', errors, () => postgresToStop?.stop());
  await stopResource('Docker network', errors, () => networkToStop?.stop());

  if (errors.length > 0) {
    throw new AggregateError(errors, 'Failed to stop one or more integration harness resources');
  }
}

async function stopResource(
  name: string,
  errors: unknown[],
  stop: () => Promise<unknown> | undefined,
) {
  try {
    await stop();
  } catch (error) {
    console.error(`Failed to stop ${name}`, error);
    errors.push(error);
  }
}
