import { createServer } from 'node:http'

const PORT = Number(process.env.PORT || 8080)
const POSTHOG_API_KEY = process.env.POSTHOG_API_KEY || ''
const POSTHOG_HOST = (process.env.POSTHOG_HOST || 'https://us.i.posthog.com').replace(/\/$/, '')
const WEBHOOK_SHARED_SECRET = process.env.WEBHOOK_SHARED_SECRET || ''

const eventMap = {
  TEST: 'revenuecat_test_event',
  INITIAL_PURCHASE: 'subscription_initial_purchase',
  NON_RENEWING_PURCHASE: 'subscription_non_renewing_purchase',
  RENEWAL: 'subscription_renewal',
  PRODUCT_CHANGE: 'subscription_product_change',
  CANCELLATION: 'subscription_cancellation',
  UNCANCELLATION: 'subscription_uncancellation',
  BILLING_ISSUE: 'subscription_billing_issue',
  SUBSCRIPTION_PAUSED: 'subscription_paused',
  TRANSFER: 'subscription_transfer',
  EXPIRATION: 'subscription_expiration'
}

function json(res, statusCode, payload) {
  res.writeHead(statusCode, { 'content-type': 'application/json' })
  res.end(JSON.stringify(payload))
}

function unauthorized(req, res) {
  console.warn(`[webhook] unauthorized request from ${req.socket.remoteAddress || 'unknown'}`)
  json(res, 401, { ok: false, error: 'unauthorized' })
}

function requireConfiguration(res) {
  json(res, 500, { ok: false, error: 'missing server configuration' })
}

function isAuthorized(req) {
  if (!WEBHOOK_SHARED_SECRET) {
    return false
  }

  const authHeader = req.headers.authorization
  if (authHeader === `Bearer ${WEBHOOK_SHARED_SECRET}`) {
    return true
  }

  const secretHeader = req.headers['x-webhook-secret']
  return secretHeader === WEBHOOK_SHARED_SECRET
}

function compact(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined && entry !== null && entry !== '')
  )
}

function toIsoTimestamp(msValue) {
  if (typeof msValue !== 'number' || Number.isNaN(msValue)) {
    return undefined
  }

  return new Date(msValue).toISOString()
}

async function parseBody(req) {
  const chunks = []

  for await (const chunk of req) {
    chunks.push(chunk)
  }

  const raw = Buffer.concat(chunks).toString('utf8')
  return raw ? JSON.parse(raw) : {}
}

function normalizeRevenueCatEvent(payload) {
  const revenueCatEvent = payload.event
  const eventName = eventMap[revenueCatEvent] || 'revenuecat_unknown_event'
  const distinctId = payload.app_user_id || payload.original_app_user_id

  if (!distinctId) {
    throw new Error('Missing RevenueCat app_user_id')
  }

  const properties = compact({
    source: 'revenuecat_webhook',
    revenuecat_event_type: revenueCatEvent,
    revenuecat_app_user_id: payload.app_user_id,
    firebase_uid: payload.app_user_id,
    original_app_user_id: payload.original_app_user_id,
    aliases: Array.isArray(payload.aliases) ? payload.aliases.join('|') : undefined,
    transferred_from: Array.isArray(payload.transferred_from) ? payload.transferred_from.join('|') : undefined,
    transferred_to: Array.isArray(payload.transferred_to) ? payload.transferred_to.join('|') : undefined,
    product_id: payload.product_id,
    store: payload.store,
    environment: payload.environment,
    entitlement_ids: Array.isArray(payload.entitlement_ids) ? payload.entitlement_ids.join('|') : undefined,
    presented_offering_id: payload.presented_offering_id,
    original_transaction_id: payload.original_transaction_id,
    transaction_id: payload.transaction_id,
    period_type: payload.period_type,
    expiration_at_ms: payload.expiration_at_ms,
    cancellation_reason: payload.cancel_reason,
    purchased_at_ms: payload.purchased_at_ms,
    price: payload.price,
    price_in_purchased_currency: payload.price_in_purchased_currency,
    currency: payload.currency,
    tax_percentage: payload.tax_percentage,
    commission_percentage: payload.commission_percentage,
    subscriber_attributes: payload.subscriber_attributes ? JSON.stringify(payload.subscriber_attributes) : undefined
  })

  return {
    distinctId,
    eventName,
    properties,
    timestamp: toIsoTimestamp(payload.event_timestamp_ms || payload.purchased_at_ms)
  }
}

async function sendToPostHog({ distinctId, eventName, properties, timestamp }) {
  const body = compact({
    api_key: POSTHOG_API_KEY,
    event: eventName,
    distinct_id: distinctId,
    properties,
    timestamp
  })

  const response = await fetch(`${POSTHOG_HOST}/capture/`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json'
    },
    body: JSON.stringify(body)
  })

  if (!response.ok) {
    const responseText = await response.text()
    throw new Error(`PostHog capture failed (${response.status}): ${responseText}`)
  }
}

const server = createServer(async (req, res) => {
  if (req.url === '/healthz' && req.method === 'GET') {
    return json(res, 200, { ok: true })
  }

  if (req.url !== '/revenuecat' || req.method !== 'POST') {
    return json(res, 404, { ok: false, error: 'not_found' })
  }

  if (!POSTHOG_API_KEY || !WEBHOOK_SHARED_SECRET) {
    return requireConfiguration(res)
  }

  if (!isAuthorized(req)) {
    return unauthorized(req, res)
  }

  try {
    const payload = await parseBody(req)
    const normalized = normalizeRevenueCatEvent(payload)

    await sendToPostHog(normalized)

    return json(res, 200, {
      ok: true,
      event: normalized.eventName,
      distinctId: normalized.distinctId
    })
  } catch (error) {
    console.error('[webhook] failed', error)
    return json(res, 400, {
      ok: false,
      error: error instanceof Error ? error.message : 'unknown_error'
    })
  }
})

server.listen(PORT, () => {
  console.log(`[webhook] listening on :${PORT}`)
})
