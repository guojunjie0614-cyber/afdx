"""箭头几何回归检查：python3 -m unittest discover -s docs/design/fig -p 'test_*.py'。"""
import math
import re
import unittest
import xml.etree.ElementTree as ET

from jssc import Fig


def points(value):
    numbers = list(map(float, re.findall(r'-?\d+(?:\.\d+)?', value)))
    return list(zip(numbers[::2], numbers[1::2]))


def drawing(pts, **kwargs):
    fig = Fig(100, 100)
    fig.arrow(pts, **kwargs)
    return ET.fromstring('<svg>' + ''.join(fig.body) + '</svg>')


class ArrowTests(unittest.TestCase):
    def test_shaft_stops_at_head_base_in_every_direction(self):
        for tip in [(80, 50), (20, 50), (50, 80), (50, 20), (80, 80)]:
            with self.subTest(tip=tip):
                svg = drawing([(50, 50), tip], sw=1.6)
                shaft = points(svg.find('path').get('d'))
                head = points(svg.find('polygon').get('points'))
                self.assertEqual(head[0], tip)
                base = tuple((a + b) / 2 for a, b in zip(head[1], head[2]))
                self.assertLess(math.dist(shaft[-1], base), .02)
                self.assertGreater(math.dist(shaft[-1], tip), 5)

    def test_short_bidirectional_heads_leave_visible_shaft(self):
        svg = drawing([(50, 57), (50, 49)], head='both', sw=.9)
        shaft = points(svg.find('path').get('d'))
        self.assertGreater(shaft[0][1], shaft[-1][1])
        self.assertGreater(math.dist(*shaft), 1)
        heads = svg.findall('polygon')
        self.assertEqual(points(heads[0].get('points'))[0], (50, 57))
        self.assertEqual(points(heads[1].get('points'))[0], (50, 49))

    def test_short_elbow_head_stays_after_bend(self):
        svg = drawing([(20, 20), (40, 20), (40, 22)])
        shaft = points(svg.find('path').get('d'))
        self.assertEqual(shaft[:2], [(20, 20), (40, 20)])
        self.assertGreater(shaft[-1][1], 20)
        self.assertLess(shaft[-1][1], 22)

    def test_start_arrow_keeps_other_endpoint(self):
        svg = drawing([(10, 20), (50, 20)], head='start', dash=True)
        path = svg.find('path')
        self.assertEqual(points(path.get('d')), [(15.5, 20), (50, 20)])
        self.assertEqual(path.get('stroke-dasharray'), '3 2')

    def test_unheaded_waveform_is_unchanged(self):
        pts = [(10, 20), (30, 20), (30, 20), (30, 40)]
        svg = drawing(pts, head=None)
        self.assertEqual(points(svg.find('path').get('d')), pts)
        self.assertEqual(svg.findall('polygon'), [])


if __name__ == '__main__':
    unittest.main()
