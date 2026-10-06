# Airlock's four sounds: where they come from

Card D1 (Feel & Finish, Phase D). One family, "soft glass", picked by the
owner by ear on 2026-10-06 from 15 candidates.

| File | Moment | Candidate | ElevenLabs generation |
|---|---|---|---|
| `AirlockNeedsYou.wav` | A request is waiting | needs C | `4Eb6EHWdainR6S98zo43` |
| `AirlockDone.wav` | An agent finished | done C | `fd1dDAZNsTGfcLUPfG8q` |
| `AirlockApproved.wav` | You approved | approved A | `KkTGjd9qavpZXm63J81y` |
| `AirlockWentWrong.wav` | Something went wrong | wrong A | `SOgVBYi5S5VTl6uqXoMc` |

## Made with

ElevenLabs Sound Effects (`eleven_text_to_sound_v2`), flow
`yfIvHssgK9IWkDj4NjrP`, on the owner's **paid Pro plan**, 2026-10-06.
Prompts, all at prompt influence 0.6:

- Needs you, 1.0 s: "Two soft rounded glass chime notes, gentle rising
  interval, close-mic, warm and clean, short natural decay, calm notification"
- Done, 0.6 s: "Short rising two-note soft glass chime, bright and pleased,
  close-mic, clean, quick decay, success notification"
- Approved, 0.5 s: "Single tiny soft glass tap, muted, delicate click,
  close-mic, very short, no reverb"
- Went wrong, 0.6 s: "Low soft glass tone, two gentle descending notes, muted
  and warm, close-mic, short decay, calm error notification"

Then trimmed, given a 2 ms fade in and a 40 ms fade out, and set a little
under the Mac's own alerts. The loudest 50 ms of the Mac alerts is about
-21 dBFS; these are -24 (needs you), -25 (done), -26 (went wrong) and
-28 (approved), with peaks at -3 dBFS or lower. They are 16-bit, 44.1 kHz
stereo WAV.

## The right to ship them in a paid app

Read from ElevenLabs' own terms on 2026-10-06:

- **Commercial use.** Terms of Use §1(c): paid users "may use the Services
  for commercial purposes".
- **Ownership.** §4(c)(ii): "as between you and ElevenLabs, you retain all
  rights in and to your Output".
- **After cancelling.** Help centre: "Content generated during a paid
  subscription can be used commercially, and indefinitely." All four were
  generated during the paid plan.
- **Credit.** No attribution is needed on paid plans.
- **Not exclusive.** The service "may produce the same or similar Output" for
  someone else. ElevenLabs also keeps a licence to use outputs to improve its
  services.
- **Sharing.** The Sound Effects terms let you opt out of ElevenLabs offering
  your SFX outputs to other users ("Disable"). The owner sets that in the
  account.

Sources: https://elevenlabs.io/terms-of-use,
https://elevenlabs.io/sound-effects-terms,
https://elevenlabs.io/docs/help-center/legal/can-i-publish-the-content-i-generate-on-the-platform
