//Visualizer of the coloring algorithm
use std::f64::consts::PI;

pub struct GraphNode {
    pub label: String,
    pub color: String,
}

pub struct FunctionGraph {
    pub name: String,
    pub nodes: Vec<GraphNode>,
    pub edges: Vec<(usize, usize)>,
}

fn hsl_to_rgb(h: f64, s: f64, l: f64) -> (u8, u8, u8) {
    if s == 0.0 {
        let v = (l * 255.0).round() as u8;
        return (v, v, v);
    }
    let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let p = 2.0 * l - q;
    let hue_to_rgb = |p: f64, q: f64, t: f64| -> f64 {
        let mut t = t;
        if t < 0.0 {
            t += 1.0;
        }
        if t > 1.0 {
            t -= 1.0;
        }
        if t < 1.0 / 6.0 {
            return p + (q - p) * 6.0 * t;
        }
        if t < 1.0 / 2.0 {
            return q;
        }
        if t < 2.0 / 3.0 {
            return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
        }
        p
    };
    let r = hue_to_rgb(p, q, h + 1.0 / 3.0);
    let g = hue_to_rgb(p, q, h);
    let b = hue_to_rgb(p, q, h - 1.0 / 3.0);
    (
        (r * 255.0).round() as u8,
        (g * 255.0).round() as u8,
        (b * 255.0).round() as u8,
    )
}

pub fn register_color(reg_id: u8) -> String {
    let hue = ((reg_id as u32).wrapping_mul(137) % 360) as f64 / 360.0;
    let (r, g, b) = hsl_to_rgb(hue, 0.62, 0.55);
    format!("#{:02x}{:02x}{:02x}", r, g, b)
}

fn escape_xml_text(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

struct Panel {
    svg: String,
    width: f64,
    height: f64,
}

fn render_panel(graph: &FunctionGraph) -> Panel {
    let n = graph.nodes.len();
    let node_r = 22.0_f64;
    let radius = (n as f64 * node_r * 2.2 / (2.0 * PI)).max(140.0);
    let margin = node_r + 60.0;
    let width = radius * 2.0 + margin * 2.0;
    let height = width + 30.0;
    let center_x = width / 2.0;
    let center_y = height / 2.0 + 15.0;

    let mut positions: Vec<(f64, f64)> = Vec::with_capacity(n);
    for i in 0..n {
        let angle = 2.0 * PI * (i as f64) / (n.max(1) as f64);
        positions.push((
            center_x + radius * angle.cos(),
            center_y + radius * angle.sin(),
        ));
    }

    let mut svg = String::new();

    for &(a, b) in &graph.edges {
        let (x1, y1) = positions[a];
        let (x2, y2) = positions[b];
        svg.push_str(&format!(
            "<line x1=\"{:.1}\" y1=\"{:.1}\" x2=\"{:.1}\" y2=\"{:.1}\" stroke=\"#bbbbbb\" stroke-width=\"1\" stroke-opacity=\"0.55\"/>\n",
            x1, y1, x2, y2
        ));
    }

    for (i, node) in graph.nodes.iter().enumerate() {
        let (x, y) = positions[i];
        let label = escape_xml_text(&node.label);
        svg.push_str(&format!(
            "<circle cx=\"{:.1}\" cy=\"{:.1}\" r=\"{:.1}\" fill=\"{}\" stroke=\"#333333\" stroke-width=\"1\"/>\n",
            x, y, node_r, node.color
        ));
        svg.push_str(&format!(
            "<text x=\"{:.1}\" y=\"{:.1}\" font-size=\"8\" font-family=\"sans-serif\" text-anchor=\"middle\" dominant-baseline=\"middle\" fill=\"#000000\">{}</text>\n",
            x, y, label
        ));
    }

    svg.push_str(&format!(
        "<text x=\"12\" y=\"20\" font-size=\"14\" font-family=\"sans-serif\" fill=\"#000000\">{} ({} nodes, {} interferences)</text>\n",
        escape_xml_text(&graph.name), n, graph.edges.len()
    ));

    Panel { svg, width, height }
}

pub fn render_svg(graphs: &[FunctionGraph], out_path: &str) {
    if graphs.is_empty() {
        return;
    }

    let panels: Vec<Panel> = graphs.iter().map(render_panel).collect();
    let total_width = panels.iter().map(|p| p.width).fold(0.0_f64, f64::max);
    let total_height: f64 = panels.iter().map(|p| p.height).sum();

    let mut svg = String::new();
    svg.push_str(&format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?><svg width=\"{:.0}\" height=\"{:.0}\" viewBox=\"0 0 {:.0} {:.0}\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n",
        total_width, total_height, total_width, total_height
    ));

    let mut y_offset = 0.0_f64;
    for panel in &panels {
        svg.push_str(&format!(
            "<g transform=\"translate(0,{:.1})\">\n{}</g>\n",
            y_offset, panel.svg
        ));
        y_offset += panel.height;
    }

    svg.push_str("</svg>\n");

    let _ = std::fs::write(out_path, svg);
}
