# Rolled edge section fixture

`rolled-edge.brep` is a 10 × 10 mm crop of the procedurally modeled edge roll
from Smith's public iPhone fit-dummy example. It contains a smooth multi-section
loft clipped to its nominal envelope; it is not imported Apple CAD geometry.

The crop spans X=30..40, Y=0..10, Z=0..8.75. At Z=0.085 the measured side
station is Y=1.20. The unconstrained smooth loft has a main region and a thin
extra strip at this plane; it is deliberately not simplified to a rectangle.
The test preserves both section faces and verifies material/empty-space probes.
The old solid-first common operation returned a B-spline-supported face and
`:non_planar_profile` at this station. Plane-first intersection retains planar
support. Keep the fixture to test that case without rebuilding the full phone.
