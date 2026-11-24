"""Sweep the nominal encoder-controlled course route against the obstacle and tape."""

from itertools import product
import math


TRACK = 164
COUNTS_PER_MM = 2532 / 212
ARC = (3282 - 1094) / COUNTS_PER_MM / TRACK
PASS_OFFSET_COUNTS = 777
FIND_COUNTS = 155
NOSE, REAR, HALF_WIDTH = 75, 125, 92.5
OBSTACLE_HALF = 50
ZONE_HALF = 500


def sweep(approach_mm, initial_y, initial_heading):
    x, y, heading = -approach_mm - NOSE - OBSTACLE_HALF, initial_y, initial_heading
    separation, extent_x, extent_y = math.inf, 0.0, 0.0

    def measure():
        nonlocal separation, extent_x, extent_y
        c, s = math.cos(heading), math.sin(heading)
        half_length = (NOSE + REAR) / 2
        axle_offset = (NOSE - REAR) / 2
        cx, cy = x + axle_offset * c, y + axle_offset * s
        x_extent = half_length * abs(c) + HALF_WIDTH * abs(s)
        y_extent = half_length * abs(s) + HALF_WIDTH * abs(c)
        extent_x = max(extent_x, abs(cx) + x_extent)
        extent_y = max(extent_y, abs(cy) + y_extent)
        obstacle_on_car_axis = OBSTACLE_HALF * (abs(c) + abs(s))
        # Separating-axis gap for the chassis rectangle and 100 mm cube footprint.
        clearance = max(
            abs(cx) - x_extent - OBSTACLE_HALF,
            abs(cy) - y_extent - OBSTACLE_HALF,
            abs(cx * c + cy * s) - half_length - obstacle_on_car_axis,
            abs(-cx * s + cy * c) - HALF_WIDTH - obstacle_on_car_axis,
        )
        separation = min(separation, clearance)

    def arc(sign):
        nonlocal x, y, heading
        steps = 160
        for _ in range(steps):
            angle = heading + sign * ARC / steps
            x += sign * TRACK * (math.sin(angle) - math.sin(heading))
            y += sign * TRACK * (math.cos(heading) - math.cos(angle))
            heading = angle
            measure()

    def straight(distance):
        nonlocal x, y
        steps = 160
        dx = distance / steps * math.cos(heading)
        dy = distance / steps * math.sin(heading)
        for _ in range(steps):
            x += dx
            y += dy
            measure()

    measure()
    arc(-1)
    arc(1)
    straight((approach_mm * 11.9 - PASS_OFFSET_COUNTS) / COUNTS_PER_MM)
    arc(1)
    arc(-1)
    straight(FIND_COUNTS / COUNTS_PER_MM)
    return separation, extent_x, extent_y


def main():
    cases = [
        sweep(d, y, math.radians(angle))
        for d, y, angle in product(range(195, 236, 5), (-6, 0, 6), (-2, 0, 2))
    ]
    gap = min(case[0] for case in cases)
    extent_x = max(case[1] for case in cases)
    extent_y = max(case[2] for case in cases)
    print(f"{len(cases)} sampled cases, minimum separating-axis gap {gap:.1f} mm")
    print(f"maximum chassis envelope: x +/-{extent_x:.1f} mm, y +/-{extent_y:.1f} mm")
    assert gap > 0, "vehicle footprint meets the obstacle"
    assert max(extent_x, extent_y) <= ZONE_HALF, "vehicle footprint leaves the zone"


if __name__ == "__main__":
    main()
