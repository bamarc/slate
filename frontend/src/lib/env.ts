function normalizeEnvironment(rawEnvironment: string | undefined): string | undefined {
  const normalized = rawEnvironment?.trim().toLowerCase();
  return normalized ? normalized : undefined;
}

export function isLocal(environment: string | undefined = import.meta.env.VITE_ENV): boolean {
  return normalizeEnvironment(environment) === "local";
}

export function isLocalOrDev(
  environment: string | undefined = import.meta.env.VITE_ENV,
): boolean {
  const normalizedEnvironment = normalizeEnvironment(environment);
  return normalizedEnvironment === "local" || normalizedEnvironment === "dev";
}
