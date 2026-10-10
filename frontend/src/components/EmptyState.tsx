export function EmptyState({ title, description = "Filter anpassen oder einen neuen Datensatz anlegen." }: { title: string; description?: string }) {
  return <div className="rounded-xl border border-dashed p-10 text-center"><p className="font-semibold text-primary">{title}</p><p className="mt-1 text-sm text-muted-foreground">{description}</p></div>;
}
