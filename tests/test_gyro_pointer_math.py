import math
import unittest


TICK_RATE = 120
FRESHNESS_SECONDS = 0.0455
SCALE_MULTIPLIERS = {"slow": 16.0, "normal": 24.0, "fast": 32.0}
GESTURE_THRESHOLD = 60.0
GYRO_REARM_SECONDS = 0.15


def optical_gesture_direction(x, y):
    if abs(x) < GESTURE_THRESHOLD and abs(y) < GESTURE_THRESHOLD:
        return None
    if abs(x) >= abs(y):
        return "left" if x < 0 else "right"
    return "up" if y < 0 else "down"


def integrate_rate(rate_degrees_per_second, seconds, scale):
    fraction = 0.0
    emitted = 0
    ticks = round(seconds * TICK_RATE)
    for _ in range(ticks):
        fraction += rate_degrees_per_second / TICK_RATE * scale
        whole = math.floor(fraction + 1e-9) if fraction >= 0 else math.ceil(fraction - 1e-9)
        fraction -= whole
        emitted += whole
    return emitted, fraction


def counts_per_degree(display_width, preset):
    return display_width / 360.0 * SCALE_MULTIPLIERS[preset]


def gyro_pointer_delta(pitch_rate, yaw_rate, seconds, scale):
    return -yaw_rate * seconds * scale, -pitch_rate * seconds * scale


def player_space_yaw(gyro_y, gyro_z, accel_x, accel_y, accel_z):
    gravity_length = math.sqrt(accel_x * accel_x + accel_y * accel_y + accel_z * accel_z)
    if gravity_length < 0.1:
        return gyro_z
    gravity_y = accel_y / gravity_length
    gravity_z = accel_z / gravity_length
    world_yaw = gyro_y * gravity_y + gyro_z * gravity_z
    relaxed = min(abs(world_yaw) * math.sqrt(2.0), math.hypot(gyro_y, gyro_z))
    return math.copysign(relaxed, world_yaw) if world_yaw else 0.0


class GyroPointerMathTests(unittest.TestCase):
    def test_speed_presets_map_rotation_linearly(self):
        display_width = 1728.0
        for name in SCALE_MULTIPLIERS:
            scale = counts_per_degree(display_width, name)
            emitted, fraction = integrate_rate(90.0, 1.0, scale)
            self.assertEqual(emitted, round(90.0 * scale), name)
            self.assertAlmostEqual(fraction, 0.0, places=6)

    def test_22_5_degree_turn_matches_display_width_at_slow(self):
        display_width = 1728.0
        emitted, fraction = integrate_rate(
            22.5, 1.0, counts_per_degree(display_width, "slow")
        )
        self.assertEqual(emitted, int(display_width))
        self.assertAlmostEqual(fraction, 0.0, places=6)

    def test_fractional_carry_preserves_slow_motion(self):
        scale = counts_per_degree(1728.0, "normal")
        emitted, fraction = integrate_rate(0.25, 2.0, scale)
        self.assertEqual(emitted, 57)
        self.assertAlmostEqual(fraction, 0.6, places=6)

    def test_rightward_yaw_moves_pointer_right(self):
        dx, _ = gyro_pointer_delta(0.0, -20.0, 0.1, 1.0)
        self.assertGreater(dx, 0.0)

    def test_player_space_yaw_survives_controller_orientation(self):
        root_half = math.sqrt(0.5)
        flat = player_space_yaw(0.0, -20.0, 0.0, 0.0, 1.0)
        upright = player_space_yaw(-20.0, 0.0, 0.0, 1.0, 0.0)
        diagonal = player_space_yaw(
            -20.0 * root_half,
            -20.0 * root_half,
            0.0,
            root_half,
            root_half,
        )
        self.assertAlmostEqual(flat, -20.0, places=5)
        self.assertAlmostEqual(upright, -20.0, places=5)
        self.assertAlmostEqual(diagonal, -20.0, places=5)

    def test_fusion_averages_without_doubling(self):
        left_pitch_yaw = (20.0, 40.0)
        right_pitch_yaw = (24.0, 36.0)
        fused = tuple((left + right) * 0.5 for left, right in zip(left_pitch_yaw, right_pitch_yaw))
        self.assertEqual(fused, (22.0, 38.0))

    def test_stale_sample_boundary(self):
        now = 10.0
        self.assertTrue(now - (now - FRESHNESS_SECONDS + 0.0001) <= FRESHNESS_SECONDS)
        self.assertFalse(now - (now - FRESHNESS_SECONDS - 0.001) <= FRESHNESS_SECONDS)

    def test_pickup_requires_short_stationary_rearm(self):
        self.assertFalse(0.149 >= GYRO_REARM_SECONDS)
        self.assertTrue(0.150 >= GYRO_REARM_SECONDS)

    def test_bias_average_removes_stationary_offset(self):
        stationary = [0.18, 0.22, 0.20, 0.19, 0.21]
        bias = sum(stationary) / len(stationary)
        corrected = [sample - bias for sample in stationary]
        self.assertAlmostEqual(sum(corrected), 0.0, places=6)

    def test_optical_gesture_waits_for_threshold(self):
        self.assertIsNone(optical_gesture_direction(59.0, -59.0))

    def test_optical_gesture_uses_dominant_axis(self):
        self.assertEqual(optical_gesture_direction(-80.0, 20.0), "left")
        self.assertEqual(optical_gesture_direction(80.0, 20.0), "right")
        self.assertEqual(optical_gesture_direction(20.0, -80.0), "up")
        self.assertEqual(optical_gesture_direction(20.0, 80.0), "down")


if __name__ == "__main__":
    unittest.main()
