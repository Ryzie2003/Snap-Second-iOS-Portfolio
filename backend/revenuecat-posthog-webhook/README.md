# RevenueCat to PostHog Webhook

Small Cloud Run-ready receiver that forwards RevenueCat subscription lifecycle webhooks into PostHog.

## Environment

Set these variables in your deployment:

- `POSTHOG_API_KEY`: PostHog project API key.
- `POSTHOG_HOST`: Optional. Defaults to `https://us.i.posthog.com`.
- `WEBHOOK_SHARED_SECRET`: Shared secret expected in `Authorization: Bearer ...` or `X-Webhook-Secret`.
- `PORT`: Optional. Defaults to `8080`.

## Local Run

```bash
cd backend/revenuecat-posthog-webhook
POSTHOG_API_KEY=phc_xxx \
WEBHOOK_SHARED_SECRET=replace-me \
node server.mjs
```

## RevenueCat Setup

Point the RevenueCat webhook URL to:

```text
https://<your-service>/revenuecat
```

Configure RevenueCat to send the same shared secret in the `Authorization` header:

```text
Authorization: Bearer <WEBHOOK_SHARED_SECRET>
```

## PostHog Events

The receiver maps RevenueCat webhook types into PostHog events such as:

- `subscription_initial_purchase`
- `subscription_non_renewing_purchase`
- `subscription_renewal`
- `subscription_product_change`
- `subscription_cancellation`
- `subscription_expiration`

Each event includes the RevenueCat app user ID as both:

- `distinct_id`
- `firebase_uid`

This assumes the iOS app keeps RevenueCat logged in with the Firebase UID from anonymous onboarding onward.
