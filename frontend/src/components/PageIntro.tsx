export function PageIntro({ eyebrow, title, description }: { eyebrow: string; title: string; description: string }) {
  return (
    <header className="space-y-1">
      <p className="text-xs font-bold uppercase tracking-[0.18em] text-primary">{eyebrow}</p>
      <h1 className="text-3xl font-extrabold tracking-tight lg:text-4xl">{title}</h1>
      <p className="max-w-3xl text-muted-foreground">{description}</p>
    </header>
  );
}
