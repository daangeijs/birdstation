#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Find the USB capture card by name and pick its capture rate.

Reads /proc/asound only, so it works while ffmpeg holds the device open.
"""

from __future__ import annotations

import glob
import os
import re

from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = r"""
module: birdmic_alsa_probe
short_description: Detect an ALSA capture card by name and choose a capture rate
description:
  - Lists sound cards from /proc/asound, picks the requested card id (or the
    first USB card with a capture stream), parses the capture rates from
    stream0 and chooses the target rate if supported, else the highest one.
  - Emits a warning when the chosen rate differs from the target, because
    ffmpeg will then resample.
options:
  card:
    description: ALSA card id (/proc/asound/cardN/id). Empty means auto-detect.
    type: str
    default: ""
  rate:
    description: Force this capture rate. 0 means probe.
    type: int
    default: 0
  target_rate:
    description: Preferred rate (the contract output rate).
    type: int
    default: 48000
  mixer_control:
    description: Simple mixer control for capture gain. Empty means the first one with a capture volume.
    type: str
    default: ""
"""

RETURN = r"""
card:
  description: Selected card id, usable as CARD=<id>.
  type: str
capture_rate:
  description: Rate to open the device with.
  type: int
resample:
  description: True when capture_rate differs from target_rate.
  type: bool
rates:
  description: Discrete capture rates the card reports.
  type: list
ranges:
  description: Continuous capture rate ranges as [min, max].
  type: list
mixer_control:
  description: Capture gain control, empty if none was found.
  type: str
cards:
  description: Every card seen, for troubleshooting.
  type: list
"""


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def parse_capture(stream_text):
    """Return (rates, ranges, channels, formats) of the Capture section."""
    rates, ranges, channels, formats = set(), [], set(), set()
    in_capture = False
    for raw in stream_text.splitlines():
        line = raw.strip()
        if raw and not raw[0].isspace():
            in_capture = line.startswith("Capture:")
            continue
        if not in_capture:
            continue
        if line.startswith("Rates:"):
            for item in line.split(":", 1)[1].split(","):
                item = item.strip()
                span = re.match(r"(\d+)\s*-\s*(\d+)", item)
                if span:
                    ranges.append([int(span.group(1)), int(span.group(2))])
                elif item.isdigit():
                    rates.add(int(item))
        elif line.startswith("Channels:"):
            value = line.split(":", 1)[1].strip()
            if value.isdigit():
                channels.add(int(value))
        elif line.startswith("Format:"):
            formats.add(line.split(":", 1)[1].strip())
    return sorted(rates), ranges, sorted(channels), sorted(formats)


def list_cards():
    cards = []
    for card_dir in sorted(glob.glob("/proc/asound/card[0-9]*")):
        index = int(card_dir.rsplit("card", 1)[1])
        stream = "".join(read(p) for p in sorted(glob.glob(os.path.join(card_dir, "stream*"))))
        rates, ranges, channels, formats = parse_capture(stream)
        has_pcm_capture = bool(glob.glob(os.path.join(card_dir, "pcm*c")))
        cards.append({
            "index": index,
            "id": read(os.path.join(card_dir, "id")).strip(),
            "name": stream.splitlines()[0].strip() if stream else "",
            "usb": os.path.exists(os.path.join(card_dir, "usbid")),
            "capture": has_pcm_capture,
            "rates": rates,
            "ranges": ranges,
            "channels": channels,
            "formats": formats,
        })
    return cards


def choose_rate(rates, ranges, target):
    if target in rates or any(lo <= target <= hi for lo, hi in ranges):
        return target
    candidates = list(rates) + [hi for _, hi in ranges]
    return max(candidates) if candidates else 0


def find_mixer_control(module, card, wanted):
    rc, out, err = module.run_command(["amixer", "-c", card, "scontents"])
    if rc != 0:
        module.warn("amixer failed for card %s: %s" % (card, err.strip()))
        return ""
    controls = []
    current = None
    for line in out.splitlines():
        head = re.match(r"Simple mixer control '(.+)',\d+", line)
        if head:
            current = head.group(1)
            continue
        if current and line.strip().startswith("Capabilities:"):
            controls.append((current, line.split(":", 1)[1].split()))
            current = None
    if wanted:
        if wanted not in [name for name, _ in controls]:
            module.fail_json(msg="Mixer control '%s' not found on card %s (have: %s)"
                             % (wanted, card, ", ".join(n for n, _ in controls) or "none"))
        return wanted
    for name, caps in controls:
        if "cvolume" in caps:
            return name
    module.warn("Card %s has no capture volume control; gain is left as is." % card)
    return ""


def main():
    module = AnsibleModule(
        argument_spec={
            "card": {"type": "str", "default": ""},
            "rate": {"type": "int", "default": 0},
            "target_rate": {"type": "int", "default": 48000},
            "mixer_control": {"type": "str", "default": ""},
        },
        supports_check_mode=True,
    )
    wanted = module.params["card"]
    target = module.params["target_rate"]
    cards = list_cards()
    summary = ["%d:%s%s%s" % (c["index"], c["id"], " usb" if c["usb"] else "",
                              " capture" if c["capture"] else "") for c in cards]

    if wanted:
        matches = [c for c in cards if c["id"] == wanted]
        if not matches:
            module.fail_json(msg="ALSA card '%s' not found (cards: %s)" % (wanted, ", ".join(summary) or "none"),
                             cards=cards)
        card = matches[0]
        if not card["capture"]:
            module.fail_json(msg="ALSA card '%s' has no capture device" % wanted, cards=cards)
    else:
        usb_capture = [c for c in cards if c["usb"] and c["capture"]]
        if not usb_capture:
            module.fail_json(msg="No USB capture card found (cards: %s). Plug in the microphone "
                                 "or set birdmic_alsa_card." % (", ".join(summary) or "none"), cards=cards)
        card = usb_capture[0]
        if len(usb_capture) > 1:
            module.warn("Several USB capture cards found (%s); using '%s'. Set birdmic_alsa_card to choose."
                        % (", ".join(c["id"] for c in usb_capture), card["id"]))

    if module.params["rate"] > 0:
        rate = module.params["rate"]
    else:
        rate = choose_rate(card["rates"], card["ranges"], target)
        if not rate:
            module.fail_json(msg="Could not read capture rates of card '%s' from /proc/asound; "
                                 "set birdmic_capture_rate." % card["id"], cards=cards)

    if rate != target:
        module.warn("Card '%s' captures at %d Hz, not %d Hz; ffmpeg will resample to %d Hz."
                    % (card["id"], rate, target, target))

    mixer = find_mixer_control(module, card["id"], module.params["mixer_control"])

    module.exit_json(
        changed=False,
        card=card["id"],
        card_index=card["index"],
        card_name=card["name"],
        capture_rate=rate,
        resample=rate != target,
        rates=card["rates"],
        ranges=card["ranges"],
        channels=card["channels"],
        formats=card["formats"],
        mixer_control=mixer,
        cards=cards,
    )


if __name__ == "__main__":
    main()
