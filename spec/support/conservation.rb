# frozen_string_literal: true

# **The one tolerance every conservation assertion is written against.**
#
# Relative rather than absolute, because the absolute energies in play run to ~1e9 J and float
# epsilon scales with magnitude — and relative *to the quantity actually being handled*, never to
# an opening balance: a sink starts empty, so normalising against its opening figure turns a
# relative tolerance into an absolute one and then fails on ordinary float noise at 1e7 J.
#
# It is a **contract figure rather than a fixture**: `docs/guides/build-an-operation.md` asks every
# operation for conservation to better than this, so three spec files declaring their own copy is
# three places for the contract to drift apart. Anything real is orders of magnitude bigger.
module Conservation
  TOLERANCE = 1e-9
end
