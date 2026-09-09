# Where the tuning targets come from

Every number in `MetricTarget` was measured off this rig on 2026-09-06/07, not
taken from general advice. This file is the record, so a future change to a
threshold is a decision rather than a drift.

## Why the app measures at all

The original version asked Claude to judge a JPEG by eye. That was the wrong
instrument, and the session that produced these targets is the evidence:

- The face read as "fine" while forehead luma sat at 128 and the **white
  t-shirt was brighter than the face** (158 vs 128). Nobody spots a 30-point
  gap by looking.
- The ring light was **on the camera axis**, giving forehead 115 and lit cheek
  115 — mathematically flat, no modelling at all. The image looked acceptable.
- Daylight with the shutter open put the **wall behind the head brighter than
  the face** (160 vs 136). It looks like a bright room, not like a fault.
- The **CameraController preview and the recorded file disagree.** Previews
  measured 1.1–1.25:1 cheek ratio; the actual 4K recording of the same setup
  measured 1.72:1. Judge from recordings.

## The targets

| Metric | Target | Measured evidence |
|---|---|---|
| Forehead luma | **preference**, default 165 ±15 | 128 read underexposed; 164 at 55% Elgato looked right — but a low-key look at ~119 was preferred, so this became a slider |
| Key : fill | 1.5–2.8:1 | On-axis ring gave 1.0:1 (flat). The 4K recording of the fixed rig gave 1.72:1 |
| Face − wall | ≥ +70 | Shutter open in daylight: **−23**. Shutter closed: **+64 to +70** |
| Shirt − face | negative | White tee: +27. Grey tee: −32. White cotton reflects ~2.4x skin, so no amount of light fixes it |
| Warmth | **preference**, default 8% of level | A natural frame measured top R−B +8.9 at luma 104 (8.6%). The same +15 at luma 58 is 26% — three times the saturation while the raw number barely moved, which is why this is relative and not absolute |
| Clipped | < 0.5% | Every good frame measured 0.00% |
| Crushed to black | < 5% | Shutter closed with no fill crushed **16%** of frame |

## A caution about the cheek ratio

This is the most sampling-sensitive number in the app, and the same frame can
be made to read very differently:

| How it was measured | b55 frame |
|---|---|
| Two points, one placed in the deepest shadow crease | 5.8:1 |
| Wide bands that clipped the face edge and caught background | 3.0:1 |
| Cheek **regions** constrained to the face (what the app does) | 1.25:1 |

The region measure is the honest one — the point figure was reading a shadow
crease, and the wide band was partly reading the wall. Earlier advice in this
project quoted the point-based figures and **overstated the contrast**.

So the window is defined in units of interocular distance, spans 0.40–1.20 of
it either side of the nose, and is capped against the face bounding box so it
cannot spill onto the background. Changing those constants changes the reading
materially; do it deliberately.

## Sampling geometry

All samples are placed from **facial landmarks**, not from fractions of the
face bounding box. The first version used box fractions and put the forehead
sample in the hair, reading 121 where the true value was 163.

Axes come from the eye line, so a tilted head samples the same places on the
face. `PixelBuffer` row 0 is the top of the image — verified with a
half-black/half-white fixture rather than assumed.

## The rig these assume

- Elgato Ring Light E196, ~55%, 3000K, **off-axis ~45° camera-left**, slightly
  above eye level. On-axis is what made the face flat.
- White bounce card camera-right. A card rather than a lamp so the fill keeps
  the key's 3000K — the two sides of the face measured R−B +78 and +10 when the
  shadow side had only ambient on it.
- Roller shutter **fully closed**, day or night. Half-down is the worst option:
  it does not diffuse, it just makes a moving bright slot.
- Brass lamp on the credenza as the only background practical. No RGB.
- Camera: manual exposure, manual WB 3000K, locked focus, 50 Hz, low gain.
- Mid-tone top, never white.

## Still outstanding on the rig

- Crushed-to-black sits at 9–16%: the dining side of the room has no practical.
- Focus was still on Auto at last check, and hunts for ~3 s at the start of a
  take (sharpness 8.6 rising to 16.1).


## Two corrections worth keeping

**Constants that encode taste must be controls.** Four of the numbers here started
fixed and had to become sliders — face brightness, warmth, the Magic Fix brightness
ceiling, and the warmth tolerance. Each was calibrated against one frame on one day and
then argued with its owner. A target that flags a picture someone prefers is wrong by
definition.

**Screenshots are not evidence for colour.** Most of the targets above were first
derived from screenshots of the app's own preview and from a project thumbnail. Measured
against the full-quality recordings, those understated warmth by roughly 15 points and
flattened key:fill from 1.72:1 to 1.2:1. Two different scenes from different days
returning identical numbers to one decimal was the giveaway — that is the processing
talking, not the room.

Measure colour and contrast from a recorded file. The preview is fine for exposure and
framing.
