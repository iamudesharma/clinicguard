# ClinicGuard Demo Script

Each scenario takes ~3-5 minutes. The agent speaks English or Hindi
(Devanagari or romanized) — it matches the patient's language.

---

## Scenario 1 — Chest pain (English) → expects `high`/`emergency`

1. Start the call. Agent greets.
2. "Hi, my name is Raj, I'm 54. I have pain in my chest since about an hour."
3. When asked: "It's a heaviness, like pressure. It started after climbing stairs."
4. "It goes into my left arm a bit. I'm sweating."
5. Expected: agent asks for emergency services / recommends urgent care,
   records vitals if offered, calls `assign_urgency` with `high` or `emergency`.
6. End call → **EHR summary card** appears with red/orange urgency badge.

## Scenario 2 — Allergic reaction (English) → expects `emergency`

1. "I ate peanuts at lunch and my lips are swelling."
2. "My throat feels tight and it's hard to breathe."
3. Expected: anaphylaxis protocol — instructs to call emergency services immediately,
   `assign_urgency(emergency)`.

## Scenario 3 — Pediatric fever in Hindi → expects `medium`

1. (Speak Hindi) "नमस्ते, मेरा बच्चा 2 साल का है और उसे बुखार है।"
2. "बुखार आज सुबह से है, 102 डिग्री है। वह खा-पी नहीं रहा।"
3. Expected: Hindi conversation, age-appropriate questions, `medium` urgency,
   Hindi EHR summary.

---

## What to check during the demo
- [ ] Agent speaks within ~0.5s after you stop talking
- [ ] Barge-in: talk while the agent speaks → it stops immediately (local duck <50ms)
- [ ] Transcript bubbles stream live on the phone
- [ ] EHR summary card appears **mid-call** (live extraction every 3 turns) and
      updates at the end with the urgency badge
- [ ] Hindi turn switches the agent's language mid-conversation
- [ ] With Supabase configured: summary card updates via realtime, no data channel
