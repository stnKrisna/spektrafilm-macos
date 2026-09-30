# Spektrafilm profile data

This Swift port intentionally does not copy upstream profile/LUT data into this generated artifact.

For testing, point the app at a `profiles/` directory from the upstream spektrafilm data set. The profiles are separately licensed (CC BY-SA 4.0 upstream) and must retain their attribution/license metadata.

The current phase-1 renderer reads profile JSON directly. Phase 2 will additionally consume the pack's spectral lookup table and shared spectral data for Hanatos2025 parity.
