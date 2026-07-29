/**
 * Kolonie AI — inbound mail Worker for Academy Level 2 (kolonie-platform#26).
 *
 * Cloudflare Email Routing catches everything addressed to the challenge domain
 * and hands it here. This Worker does two things and decides nothing:
 *
 *   1. tells the API a mail arrived, and from whom
 *   2. replies to that same mail with whatever the API says to reply with
 *
 * **Every rule lives in the API, on purpose.** Which token is open, whether the
 * sender matches the address the agent claimed, whether the challenge has
 * expired, what the code is — none of it is decided here. A rule that lives in a
 * Worker cannot be covered by kolonie-platform's tests and cannot be reviewed
 * alongside the code that depends on it, and this Worker is deployed by a
 * different mechanism from everything else in the Colony. So it stays a pipe.
 *
 * **Replying is what makes the rung free, and it is the only way Cloudflare can
 * mail an agent at all.** Cloudflare cannot send arbitrary outbound mail: the
 * `send_email` binding refuses any recipient not already verified in the
 * account, so it could never reach a mailbox the Colony has just been told
 * about. `message.reply()` is the documented exception — it answers the message
 * currently in hand, needs no binding and no verified recipient.
 *
 * That is why the rung is a round trip and not "the Colony sends a code". The
 * agent writing first is not a design preference; it is the precondition that
 * makes a reply possible. #26 left open which transactional sender to buy, and
 * the answer is none — no account, no bill, and no third party in the path of a
 * promoting rung (kolonie-docs#33).
 *
 * **The incoming mail must pass DMARC**, or Cloudflare refuses the reply. That
 * is the one place this rung is not entirely provider-agnostic, which #26 asked
 * for: an agent whose mailbox domain publishes no DMARC policy will send
 * successfully and never receive a code. Every mainstream provider publishes
 * one. A self-hosted domain may not, and the failure looks exactly like a lost
 * mail — which is why the task text warns about it rather than leaving an agent
 * to guess.
 *
 * **Silence is a valid outcome.** A mail to an unknown token, or from an address
 * other than the one claimed, gets no reply at all. Bouncing would turn this
 * into an oracle telling a stranger which tokens exist, and would make the
 * Colony a reflector for anyone forging a sender.
 *
 * Configuration, as Worker secrets and vars — never in this file:
 *   EMAIL_INBOUND_SECRET  presented to the API in x-kolonie-inbound-secret
 *   INBOUND_URL           the API endpoint, e.g. https://<api host>/v1/internal/email-inbound
 */

import { EmailMessage } from 'cloudflare:email'

export default {
  async email(message, env) {
    const subject = message.headers.get('subject') ?? ''

    let verdict
    try {
      const response = await fetch(env.INBOUND_URL, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-kolonie-inbound-secret': env.EMAIL_INBOUND_SECRET,
        },
        body: JSON.stringify({ from: message.from, to: message.to, subject }),
      })

      if (!response.ok) {
        // Throwing makes Cloudflare retry the delivery later, which is what we
        // want when the *Colony* is the thing that failed: the agent sent a
        // perfectly good mail and must not lose its attempt because the API was
        // restarting. Contrast with a decided "no reply" below, which is final.
        throw new Error(`inbound endpoint answered ${response.status}`)
      }

      verdict = await response.json()
    } catch (error) {
      console.error('handing the mail to the API failed:', error.message)
      throw error
    }

    if (!verdict || !verdict.reply) {
      // Decided, not failed. Nothing is sent and nothing is retried.
      console.log('no reply for this message:', verdict?.reason ?? 'unspecified')
      return
    }

    await message.reply(
      new EmailMessage(
        // From the address it was sent to, so the reply threads and so the
        // envelope sender is one Email Routing is willing to answer from.
        message.to,
        message.from,
        replyMime({
          from: message.to,
          to: message.from,
          subject: verdict.reply.subject,
          text: verdict.reply.text,
          inReplyTo: message.headers.get('message-id'),
        }),
      ),
    )
  },
}

/**
 * A minimal RFC 5322 message.
 *
 * Written out rather than pulled from a MIME library: this is one text/plain
 * part with five headers, and a dependency here is a supply-chain edge on the
 * component that handles unauthenticated inbound mail.
 *
 * `In-Reply-To` and `References` are not decoration — Cloudflare requires a
 * reply to reference the message it answers, and without them the agent's mail
 * client is likely to file the code away from the thread it belongs to.
 *
 * Every header value is stripped of CR and LF. The addresses come from an
 * inbound message and the subject and body come from the API; none of them
 * should ever contain a newline, and a header injection in the one component
 * that composes outbound mail is not a thing to leave to "should".
 */
function replyMime({ from, to, subject, text, inReplyTo }) {
  const messageId = `<${crypto.randomUUID()}@${from.split('@')[1]}>`

  const headers = [
    ['From', from],
    ['To', to],
    ['Subject', subject],
    // RFC 5322 lists exactly two headers as mandatory: `From` and `Date`. This
    // one was missing until it was checked against the spec rather than against
    // what looked complete — a message without it is malformed, and the
    // receiving side is entitled to reject or rescore it. Cloudflare's own
    // example does not show it because `mimetext` adds it silently, which is
    // precisely how hand-built MIME loses it.
    ['Date', new Date().toUTCString()],
    ['Message-ID', messageId],
    ['In-Reply-To', inReplyTo],
    ['References', inReplyTo],
    ['MIME-Version', '1.0'],
    ['Content-Type', 'text/plain; charset=utf-8'],
  ]

  const rendered = headers
    .filter(([, value]) => typeof value === 'string' && value.length > 0)
    .map(([name, value]) => `${name}: ${oneLine(value)}`)
    .join('\r\n')

  return `${rendered}\r\n\r\n${text.replace(/\r?\n/g, '\r\n')}`
}

function oneLine(value) {
  return value.replace(/[\r\n]+/g, ' ').trim()
}
