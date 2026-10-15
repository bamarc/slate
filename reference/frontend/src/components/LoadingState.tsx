export function LoadingState({ label = "Daten werden geladen ..." }: { label?: string }) {
  return <div className="flex min-h-32 items-center justify-center text-sm text-muted-foreground" role="status">{label}</div>;
}
