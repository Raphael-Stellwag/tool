const fs = require('fs').promises
const { promisified_spawn } = require('../util/exec')
const path = require('path')
const ipUtil = require('../util/ip-util')
const math = require('mathjs')
const { removeOutliers, isNullOrEmpty } = require('../util/helpers')
const TOML = require('@iarna/toml')
const auth = {
  peers: {
    scheme: 'Ed25519',
    pubKeyPrefix: 'ed-25519-public-',
    pvKeyPrefix: 'ed-25519-private-',
    certPrefix: 'ed-25519-cert-',
  },
  clients: {
    scheme: 'Hmac',
  },
}

function _parse(replicaSettings, clientSettings) {
  if (isNullOrEmpty(replicaSettings))
    throw new Error('replica object of current experiment was not defined')
  if (isNullOrEmpty(clientSettings))
    throw new Error('client object of current experiment was not defined')
  if (isNullOrEmpty(replicaSettings.replicas))
    throw new Error(
      'replicas property of replicas object of current experiment was not defined',
    )
  if (!Number.isInteger(replicaSettings.replicas))
    throw new Error('replicas property of replica object must be an Integer')
  if (
    isNullOrEmpty(replicaSettings.minBatchSize) ||
    isNullOrEmpty(replicaSettings.maxBatchSize)
  )
    throw new Error(
      'minBatchSize and maxBatchSize properties of replica object of current experiment was not defined',
    )
  if (
    !Number.isInteger(replicaSettings.minBatchSize) ||
    !Number.isInteger(replicaSettings.maxBatchSize)
  )
    throw new Error(
      'minBatchSize and maxBatchSize properties of replica object must be an Integer',
    )
  if (isNullOrEmpty(replicaSettings.replySize))
    throw new Error(
      'replySize property of replica object of current experiment was not defined',
    )
  if (!Number.isInteger(replicaSettings.replySize))
    throw new Error('replySize property of replica object must be an Integer')
  if (isNullOrEmpty(replicaSettings.batchReplies))
    throw new Error(
      'batchReplies property of replica object of current experiment was not defined',
    )
  if (!math.isBoolean(replicaSettings.batchReplies))
    throw new Error(
      'batchReplies property of replica object must be an Integer',
    )
  if (isNullOrEmpty(clientSettings.clients))
    throw new Error(
      'clients property of client object of current experiment was not defined',
    )
  if (!Number.isInteger(clientSettings.clients))
    throw new Error('clients property of client object must be an Integer')
  if (isNullOrEmpty(clientSettings.concurrent))
    throw new Error(
      'concurrent property of client object of current experiment was not defined',
    )
  if (!Number.isInteger(clientSettings.concurrent))
    throw new Error('concurrent property of client object must be an Integer')
  if (isNullOrEmpty(clientSettings.payload))
    throw new Error(
      'payload property of client object of current experiment was not defined',
    )
  if (!Number.isInteger(clientSettings.payload))
    throw new Error('payload property of client object must be an Integer')
  if (isNullOrEmpty(clientSettings.duration))
    throw new Error(
      'duration property of client object of current experiment was not defined',
    )
  if (!Number.isInteger(clientSettings.duration))
    throw new Error('duration property of client object must be an Integer')
}

function resolveRustLogLevels(replicaSettings, clientSettings) {
  const replicaLog =
    (!isNullOrEmpty(replicaSettings.rustLog) && replicaSettings.rustLog) ||
    (!isNullOrEmpty(replicaSettings.rust_log) && replicaSettings.rust_log) ||
    'info'
  const clientLog =
    (!isNullOrEmpty(clientSettings.rustLog) && clientSettings.rustLog) ||
    (!isNullOrEmpty(clientSettings.rust_log) && clientSettings.rust_log) ||
    replicaLog
  return { replicaLog, clientLog }
}

async function build(replicaSettings, clientSettings, log) {
  log.info('building Themis ...')
  let cmd = { proc: 'cargo', args: ['build', '--bins', '--release'] }
  await promisified_spawn(cmd.proc, cmd.args, process.env.THEMIS_LEGO_BFT_DIR, log)
  log.info('Themis build terminated sucessfully!')
}
async function generateKeys(numKeys, log) {
  log.info(`generating keys for ${numKeys} replicas...`)
  try {
    await fs.mkdir(
      path.join(process.env.THEMIS_LEGO_BFT_DIR, process.env.THEMIS_LEGO_BFT_KEYS_DIR),
      { recursive: true }
    )
  } catch (error) {
    log.warn('using a pre-existing keys directory')
  }
  let cmd = {
    proc: 'cargo',
    args: [
      'run',
      '--bin',
      'keygen',
      '--',
      auth.peers.scheme,
      '0',
      numKeys,
      '--out-dir',
      process.env.THEMIS_LEGO_BFT_KEYS_DIR,
    ],
  }
  await promisified_spawn(cmd.proc, cmd.args, process.env.THEMIS_LEGO_BFT_DIR, log)
  log.info('keys generated successfully!')
}
async function createConfigFile(replicaSettings, log) {
  log.info('generating Themis config ...')
  let faults = Math.floor((replicaSettings.replicas - 1) / 3);

  const reliableSenderCache =
    replicaSettings.reliable_sender_cache !== undefined
      ? replicaSettings.reliable_sender_cache
      : false
  const batchMinDelay =
    replicaSettings.batchMinDelay ||
    replicaSettings.batch_min_delay || {
      secs: 0,
      nano: 0,
    }
  const batchMinDelaySecs = Number(batchMinDelay.secs ?? 0)
  const batchMinDelayNanos = Number(
    batchMinDelay.nanos ?? batchMinDelay.nano ?? 0,
  )
  const checkpointInterval = Number(
    replicaSettings.checkpointInterval ??
    replicaSettings.checkpoint_interval ??
    1200,
  )
  const authenticationClients =
    replicaSettings.authenticationClients ??
    replicaSettings.authentication_clients ??
    'Blake3'
  const brachaAuthenticationPeers =
    replicaSettings.brachaAuthenticationPeers ??
    replicaSettings.bracha_authentication_peers ??
    'Blake3'
  const pbftAuthenticationPeers =
    replicaSettings.pbftAuthenticationPeers ??
    replicaSettings.pbft_authentication_peers ??
    'Ed25519'

  let config = {
    reply_size: replicaSettings.replySize,
    execution: 'Single',
    batching: replicaSettings.batchReplies,
    faults: faults,
    response_store: {
      enable: replicaSettings.enable_response_store !== undefined
        ? replicaSettings.enable_response_store
        : true,
    },
    client: {
      request_strategy: "round-robin-fixed",
      wait_on_all_replicas_to_be_ready: true
    },
    communication: {
      max_parallel_requests_per_client: replicaSettings.max_parallel_requests_per_client,
      max_request_size: 100_000_000,
      max_protocol_size: 15_000_000_000,
      reliable_sender_cache: reliableSenderCache,
    },
    authentication: {
      clients: authenticationClients,
    },
    batch: {
      timeout: {
        secs: Number(replicaSettings.batchTimeout.secs),
        nanos: Number(replicaSettings.batchTimeout.nano),
      },
      min_delay: {
        secs: batchMinDelaySecs,
        nanos: batchMinDelayNanos,
      },
      min: Number(replicaSettings.minBatchSize),
      max: Number(replicaSettings.maxBatchSize),
    },
    checkpoint: {
      keep_checkpoints: 2
    }
  }

  // Peers
  let hostIPs = await ipUtil.getIPs({
    [process.env.THEMIS_LEGO_BFT_REPLICA_HOST_PREFIX]: replicaSettings.replicas,
    [process.env.THEMIS_LEGO_BFT_CLIENT_HOST_PREFIX]: 1, // FOR NOW?
  })
  for (let i = 0; i < hostIPs.length; i++) {
    if (hostIPs[i].name.startsWith(process.env.THEMIS_LEGO_BFT_REPLICA_HOST_PREFIX))
      hostIPs[i].isClient = false
    else hostIPs[i].isClient = true
  }
  config.client_peers = []
  config.protocols = [
    {
      "name": "batching"
    },
    {
      "name": "bracha-rbc",
      "authentication": {
        "peers": brachaAuthenticationPeers,
      },
      "config": {
        "faults": faults,
        "verify_proposal": false,
        "hashed_echo_and_ready": true,
        "request_proposals": false,
        "hashed_batching": replicaSettings.bracha_hashed_batching,
        "hashed_batch_size": replicaSettings.bracha_hashed_batch_size,
        "hashed_batch_timeout_ms": replicaSettings.bracha_hashed_batch_timeout_ms,
      },
      "peers": []
    },
    {
      "name": "pbft",
      "authentication": {
        "peers": pbftAuthenticationPeers,
      },
      "config": {
        "faults": faults,
        "first_primary": 0,
        "checkpoint_interval": checkpointInterval,
        "high_mark_delta": 3200,
        "request_timeout": replicaSettings.requestTimeout,
        "primary_forwarding": 'None',
        "backup_forwarding": 'None',
        "reply_mode": 'All',
        "timer_granularity": "proposal",
        "request_proposals": false,
        "remove_duplicate_requests": false,
      },
      "peers": [

      ]
    }
  ]


  let replicaId = 0
  for (let i = 0; i < hostIPs.length; i++) {
    if (hostIPs[i].isClient) continue

    config.client_peers.push({
      id: replicaId,
      host: hostIPs[i].ip,
      client_port: Number(process.env.THEMIS_LEGO_BFT_CLIENT_PORT),
      private_key: `${process.env.THEMIS_LEGO_BFT_KEYS_DIR}/${auth.peers.pvKeyPrefix}${replicaId}`,
      public_key: `${process.env.THEMIS_LEGO_BFT_KEYS_DIR}/${auth.peers.pubKeyPrefix}${replicaId}`,
    })

    for (let j = 0; j < config.protocols.length; j++) {
      if (Object.hasOwn(config.protocols[j], "peers")) {
        config.protocols[j].peers.push({
          id: replicaId,
          host: hostIPs[i].ip,
          peer_port: Number(process.env.THEMIS_LEGO_BFT_REPLICA_PORT) + j,
          private_key: `${process.env.THEMIS_LEGO_BFT_KEYS_DIR}/${auth.peers.pvKeyPrefix}${replicaId}`,
          public_key: `${process.env.THEMIS_LEGO_BFT_KEYS_DIR}/${auth.peers.pubKeyPrefix}${replicaId}`,
        })
      }
    }

    replicaId++
  }

  let configString = TOML.stringify(config)
  const configPath = path.join(
    process.env.THEMIS_LEGO_BFT_DIR,
    process.env.THEMIS_LEGO_BFT_CONFIG_FILE_PATH,
  )

  await fs.mkdir(path.dirname(configPath), { recursive: true })
  log.info("writing file out")
  await fs.writeFile(configPath, configString)
  log.info('Config file generated!, saving to ' + configPath)
  return hostIPs
}
async function passArgs(hosts, replicaSettings, clientSettings, log) {
  const { replicaLog, clientLog } = resolveRustLogLevels(
    replicaSettings,
    clientSettings,
  )
  let replicaIndex = 0
  let clientIndex = 0
  for (let i = 0; i < hosts.length; i++) {
    if (hosts[i].isClient) {
      hosts[i].procs = []
      hosts[i].procs.push({
        path: path.join(process.env.THEMIS_LEGO_BFT_DIR, process.env.THEMIS_LEGO_BFT_CLIENT_BIN),
        env: `RUST_LOG=${clientLog}`,
        args: `-d ${clientSettings.duration} --config ${process.env.THEMIS_LEGO_BFT_CONFIG_PATH} --payload ${clientSettings.payload} -c ${clientSettings.clients} --concurrent ${clientSettings.concurrent} --response-strategy ${clientSettings.response_strategy}`,
        startTime: clientSettings.startTime ? clientSettings.startTime : 0,
      })
      clientIndex++
      continue
    }
    hosts[i].procs = []
    hosts[i].procs.push({
      path: path.join(process.env.THEMIS_LEGO_BFT_DIR, process.env.THEMIS_LEGO_BFT_REPLICA_BIN),
      env: `RUST_LOG=${replicaLog}`,
      args: `${replicaIndex} --config ${process.env.THEMIS_LEGO_BFT_CONFIG_PATH}`,
      start_time: 0,
    })
    replicaIndex++
  }
  return hosts
}
function getExecutionDir() {
  return process.env.THEMIS_LEGO_BFT_EXECUTION_DIR
}
function getExperimentsOutputDirectory() {
  return process.env.THEMIS_LEGO_BFT_EXPERIMENTS_OUTPUT_DIR
}
async function configure(replicaSettings, clientSettings, log) {
  log.info('parsing replica and client objects')
  _parse(replicaSettings, clientSettings)
  log.info('objects parsed!')
  await generateKeys(replicaSettings.replicas, log)
  let hosts = await createConfigFile(replicaSettings, log)
  hosts = await passArgs(hosts, replicaSettings, clientSettings, log)
  return hosts
}

function getProcessName() {
  return 'themis-bench-app'
}

async function getStats(experimentId, log) {
  const readline = require('readline')
  const fsStream = require('fs')

  const clientFilePath = path.join(
    process.env.THEMIS_LEGO_BFT_EXPERIMENTS_OUTPUT_DIR,
    experimentId,
    `hosts/${process.env.THEMIS_LEGO_BFT_CLIENT_HOST_PREFIX}0/${process.env.THEMIS_LEGO_BFT_CLIENT_HOST_PREFIX}0.bench-client.1000.stdout`
  )

  // Check if file exists
  try {
    await fs.access(clientFilePath)
  } catch (e) {
    log.warn(`Client log file not found: ${clientFilePath}`)
    return {
      maxThroughput: -1,
      avgThroughput: -1,
      latencyAll: -1,
      latencyOutlierRemoved: -1,
    }
  }

  // Use streaming to handle large files
  const RPSEntries = []
  const LAGEntries = []

  const fileStream = fsStream.createReadStream(clientFilePath)
  const rl = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity
  })

  for await (const line of rl) {
    if (line.includes('RPS:') && !line.includes('Total rps:')) {
      const rps = parseFloat(line.split('RPS: ')[1])
      if (rps > 0) RPSEntries.push(rps)
    }
    if (line.includes('LAG:') && !line.includes('Total lag:')) {
      const lag = parseFloat(line.split('LAG: ')[1])
      if (lag > 0) LAGEntries.push(lag)
    }
  }

  if (RPSEntries.length === 0 || LAGEntries.length === 0) {
    log.warn('No RPS/LAG entries found in client log')
    return {
      maxThroughput: -1,
      avgThroughput: -1,
      latencyAll: -1,
      latencyOutlierRemoved: -1,
    }
  }

  const maxThroughput = math.max(RPSEntries)
  const avgThroughput = math.mean(RPSEntries)
  const avgLag = math.mean(LAGEntries)
  const latencyOutlierRemoved = removeOutliers(LAGEntries)
  const avgLatNoOutlier = math.mean(latencyOutlierRemoved)

  return {
    maxThroughput: maxThroughput,
    avgThroughput: avgThroughput,
    latencyAll: avgLag,
    latencyOutlierRemoved: avgLatNoOutlier,
  }
}
async function postRun(experimentId, log) {
  const experimentDir = path.join(process.env.THEMIS_LEGO_BFT_EXPERIMENTS_OUTPUT_DIR, experimentId)
  const analyzeScript = path.join(__dirname, '..', '..', 'scripts', 'themis-lego-bft', 'analyze.sh')

  try {
    log.info('Running post-experiment analysis...')
    await promisified_spawn('bash', [analyzeScript, experimentDir], process.env.THEMIS_LEGO_BFT_EXECUTION_DIR, log)
    log.info('Post-experiment analysis completed')
  } catch (e) {
    log.warn(`Post-experiment analysis failed: ${e.message}`)
  }
}

module.exports = {
  build,
  configure,
  getProcessName,
  getStats,
  getExecutionDir,
  getExperimentsOutputDirectory,
  postRun,
}
