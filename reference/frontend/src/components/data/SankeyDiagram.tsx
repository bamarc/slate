import { useId, useMemo, useState } from "react";

export interface SankeyNode { name: string; category?: string; }
export interface SankeyLink { source: number; target: number; value: number; }
export interface SankeyData { nodes: SankeyNode[]; links: SankeyLink[]; }
export interface SankeyDiagramProps { data: SankeyData; height?: number; }

const COLORS = ["#0284c7", "#3b82f6", "#8b5cf6", "#f59e0b", "#10b981", "#ec4899", "#6366f1"];

export function SankeyDiagram({ data, height = 280 }: SankeyDiagramProps) {
  const prefix = useId();
  const [hovered, setHovered] = useState<number | null>(null);
  const layout = useMemo(() => {
    if (!data.nodes.length || !data.links.length) return null;
    const width = 600, padding = 24, nodeWidth = 14, depths = data.nodes.map(() => 0);
    for (const _node of data.nodes) data.links.forEach((link) => { depths[link.target] = Math.max(depths[link.target], depths[link.source] + 1); });
    const maxDepth = Math.max(...depths, 1);
    const columns = Array.from({ length: maxDepth + 1 }, () => [] as number[]);
    depths.forEach((depth, index) => columns[depth].push(index));
    const values = data.nodes.map((_, index) => Math.max(...data.links.filter((link) => link.source === index || link.target === index).map((link) => link.value), 1));
    const nodes = data.nodes.map(() => ({ x: 0, y: 0, h: 0 }));
    columns.forEach((column, columnIndex) => { let y = padding; const total = column.reduce((sum, index) => sum + values[index], 0); column.forEach((index) => { const h = Math.max(16, (values[index] / total) * (height - padding * 2 - Math.max(0, column.length - 1) * 16)); nodes[index] = { x: padding + (columnIndex / maxDepth) * (width - padding * 2 - nodeWidth), y, h }; y += h + 16; }); });
    return { width, nodeWidth, nodes };
  }, [data, height]);
  if (!layout) return <div className="flex h-52 items-center justify-center text-sm text-muted-foreground">Keine Daten verfügbar</div>;
  return <div className="w-full overflow-x-auto"><svg viewBox={`0 0 ${layout.width} ${height}`} className="h-auto min-w-[540px] w-full" role="img" aria-label="Sankey-Diagramm"><defs>{data.links.map((link, index) => <linearGradient id={`${prefix}-${index}`} key={index}><stop stopColor={COLORS[link.source % COLORS.length]} /><stop offset="1" stopColor={COLORS[link.target % COLORS.length]} /></linearGradient>)}</defs><g>{data.links.map((link, index) => { const source = layout.nodes[link.source], target = layout.nodes[link.target]; const x0 = source.x + layout.nodeWidth, x1 = target.x, y0 = source.y + source.h / 2, y1 = target.y + target.h / 2, dx = (x1 - x0) * 0.45; return <path d={`M${x0} ${y0} C${x0 + dx} ${y0},${x1 - dx} ${y1},${x1} ${y1}`} fill="none" stroke={`url(#${prefix}-${index})`} strokeWidth={Math.max(2, Math.sqrt(link.value))} opacity={hovered === null || hovered === index ? 0.65 : 0.15} key={index} onMouseEnter={() => setHovered(index)} onMouseLeave={() => setHovered(null)}><title>{`${data.nodes[link.source].name} -> ${data.nodes[link.target].name}: ${link.value}`}</title></path>; })}</g><g>{layout.nodes.map((node, index) => <g key={index}><rect x={node.x} y={node.y} width={layout.nodeWidth} height={node.h} rx="3" fill={COLORS[index % COLORS.length]} /><text x={node.x < layout.width / 2 ? node.x + layout.nodeWidth + 8 : node.x - 8} y={node.y + node.h / 2} dy=".35em" textAnchor={node.x < layout.width / 2 ? "start" : "end"} className="fill-foreground text-[11px]">{data.nodes[index].name}</text></g>)}</g></svg></div>;
}
