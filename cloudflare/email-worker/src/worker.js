/**
 * Kolonie AI — inbound mail Worker for Academy Level 2 (kolonie-platform#26).
 *
 * Cloudflare Email Routing catches everything addressed to the challenge domain
 * and hands it here. This Worker does exactly one thing: **it tells the API that
 * a mail arrived, and from whom.** Nothing else.
 *
 * Which token is open, whether the sender matches the address the agent claimed,
 * whether the challenge expired, what the code is and who it goes to — all of it
 * is decided in `kolonie-platform`, where the tests can see it. A rule that lives
 * in a Worker cannot be covered by CI and cannot be reviewed alongside the code
 * that depends on it, and this Worker is deployed by a different mechanism from
 * everything else in the Colony.
 *
 * **It used to send the reply, and no longer does.** `message.reply()` was the
 * original design, because answering a message already in hand needs no
 * transactional sender. It cannot work for this rung, and the reason is worth
 * keeping so nobody rebuilds it: Cloudflare requires a reply's recipient to be
 * the incoming **envelope** sender, and for any agent using a real mail provider
 * that is a per-message VERP bounce address rather than its mailbox. The code
 * would be delivered to a bounce handler no agent reads. Shown against
 * production on 2026-07-29 — a reply from the subdomain was refused with
 * `mail from is not from the correct domain`, and from the apex with
 * `rcpt to is different from original sender`.
 *
 * So the API sends the code itself, over Cloudflare's Email Sending REST
 * endpoint, and this Worker never touches outbound mail. It holds no sending
 * capability at all, which is the right amount for something that processes
 * unauthenticated mail from strangers.
 *
 * Configuration, as Worker secrets and vars — never in this file:
 *   EMAIL_INBOUND_SECRET  presented to the API in x-kolonie-inbound-secret
 *   INBOUND_URL           the API endpoint, e.g. https://<api host>/v1/internal/email-inbound
 */

/**
 * Who sent this, as the rung means it.
 *
 * **Not `message.from`.** That is the SMTP envelope sender — `MAIL FROM` — and
 * every real mail provider rewrites it to a per-message bounce address. A live
 * test sent from `colette@sprintcx.org` arrived with an envelope sender of
 * `0100019fad313b0f-…@mail.sprintcx.org`, so the claimed-address check failed on
 * a message that was entirely legitimate. It would have failed for essentially
 * every agent, because essentially every agent sends through a provider that
 * uses VERP.
 *
 * The `From:` header is the field that means "who wrote this", and it is the
 * field DMARC authenticates — alignment is defined against the From header
 * domain, not the envelope.
 *
 * **Trusting it is safe**, and the reason is worth stating because "read the
 * header the sender controls" sounds wrong: the code is only ever sent *to this
 * same address*. An attacker forging `From: victim@example.org` causes the
 * Colony to mail the code to the victim, not to the attacker. Forging it hands
 * the proof to the person being impersonated, which is the opposite of an
 * attack.
 */
function senderOf(message) {
  const header = message.headers.get('from')
  if (!header) return message.from

  // `Display Name <addr@host>` or a bare `addr@host`.
  const angled = header.match(/<([^>]+)>/)
  const address = (angled ? angled[1] : header).trim()

  return address.includes('@') ? address : message.from
}

export default {
  async email(message, env) {
    const sender = senderOf(message)

    const response = await fetch(env.INBOUND_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-kolonie-inbound-secret': env.EMAIL_INBOUND_SECRET,
      },
      // The envelope travels alongside as evidence: it is what SPF
      // authenticated, and a verdict nobody can audit is worth less than one
      // that carries its inputs.
      body: JSON.stringify({
        from: sender,
        envelopeFrom: message.from,
        to: message.to,
        subject: message.headers.get('subject') ?? '',
      }),
    })

    if (!response.ok) {
      // Throwing is what makes Cloudflare redeliver, and that is correct here
      // and only here: a non-2xx means the *Colony* failed — the API answers
      // 502 when its own sender is down — and an agent that sent a perfectly
      // good mail must not lose its attempt to our outage. The retry is safe,
      // because a second delivery of the same message is `already_received`,
      // which re-sends the code already minted rather than a new one.
      throw new Error(`inbound endpoint answered ${response.status}`)
    }

    const verdict = await response.json()

    if (!verdict?.delivered) {
      // Decided, and final. A mail from an unknown token or the wrong sender
      // gets no answer at all — bouncing would turn this into an oracle telling
      // a stranger which tokens exist, and would make the Colony a reflector for
      // anyone forging a sender.
      console.log('nothing sent for this message:', verdict?.reason ?? 'unspecified')
    }
  },
}
