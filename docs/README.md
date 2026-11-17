# Documentation

Read in this order. Each page assumes the previous one.

| Page | What it answers |
|---|---|
| [01-setup.md](01-setup.md) | How to install, compile and start the EA for the first time. |
| [02-inputs.md](02-inputs.md) | What every input and file field does, its default and its validation rule. |
| [03-architecture.md](03-architecture.md) | How the modules fit together and how a decision flows through them. |
| [04-models.md](04-models.md) | How to train, export, install, verify and roll back ONNX models. |
| [05-validation.md](05-validation.md) | How to run every validation the specification lists, and what passes. |
| [06-deployment.md](06-deployment.md) | The research → tester → demo → micro-live staged path. |
| [07-operations.md](07-operations.md) | Daily operation, journals, kill switches, incidents and recovery. |
| [08-decisions.md](08-decisions.md) | Ambiguities, assumptions, deviations and their tradeoffs. |
| [09-verification.md](09-verification.md) | What was actually compiled and tested for this delivery, and what was not. |

## Conventions

- **Observed** means produced by a command in this repository and recorded in
  [09-verification.md](09-verification.md).
- **Derived** means read directly from the source in this repository.
- **Assumption** means a decision taken where the specification or the broker
  left a choice open. Assumptions are consolidated in
  [08-decisions.md](08-decisions.md); they are not facts.
- **Not verified** means exactly that. The absence of live Deriv evidence is
  stated explicitly wherever it matters.

All times are UTC unless a field is labelled server time. The EA converts
server time to UTC once, at the session boundary.

## Safety summary

- The risk engine is the final gate. Session, strategy, news and AI factors
  are bounded to `[0, 1]` and only multiply risk down. A zero or invalid value
  rejects the entry.
- The external AI cannot raise risk: a hard ceiling of `1.0` applies before the
  risk engine, and the configured ceiling can only be lower.
- Missing or invalid models, calendars, state or symbol data fail closed by
  default.
- Every evaluated candidate, rejection, order event and AI interaction is
  journaled.
