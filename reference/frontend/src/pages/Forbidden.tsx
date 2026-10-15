import { ShieldX } from "lucide-react";
import { isLocal } from "@/lib/env";
import { useAuth } from "@/contexts/AuthContext";
import { useNavigate } from "react-router-dom";

export default function Forbidden() {
  const { logout } = useAuth();
  const navigate = useNavigate();

  const handleZurAnmeldung = () => {
    logout();
    navigate("/login", { replace: true });
  };

  return (
    <div className="min-h-screen bg-background flex flex-col items-center justify-center p-4">
      <div className="absolute inset-0 bg-[linear-gradient(to_right,hsl(var(--border))_1px,transparent_1px),linear-gradient(to_bottom,hsl(var(--border))_1px,transparent_1px)] bg-[size:4rem_4rem] [mask-image:radial-gradient(ellipse_60%_50%_at_50%_0%,#000_70%,transparent_110%)] -z-10" />

      <div className="w-full max-w-md space-y-6 animate-slide-up text-center">
        <div className="flex flex-col items-center gap-4">
          <div className="w-16 h-16 rounded-2xl bg-primary flex items-center justify-center shadow-lg">
            <span className="text-primary-foreground font-bold text-3xl">T</span>
          </div>
          <div>
            <h1 className="text-3xl font-bold">Fullstack Template</h1>
            <p className="text-muted-foreground mt-1">React + Vite + Tailwind + FastAPI</p>
          </div>
        </div>

        <div className="rounded-xl border-0 shadow-lg bg-card p-8 space-y-4">
          <div className="flex justify-center">
            <div className="w-16 h-16 rounded-full bg-destructive/10 flex items-center justify-center">
              <ShieldX className="w-9 h-9 text-destructive" />
            </div>
          </div>

          <div className="space-y-2">
            <p className="text-4xl font-bold text-destructive">403</p>
            <h2 className="text-xl font-semibold">Zugriff verweigert</h2>
            <p className="text-muted-foreground text-sm leading-relaxed">
              Du bist zwar authentifiziert, hast aber nicht die erforderlichen Berechtigungen, um
              auf diese Seite zuzugreifen oder die Aktion auszuführen.
            </p>
          </div>

          <div className="pt-2 space-y-2">
            {isLocal() ? (
              <button
                onClick={handleZurAnmeldung}
                className="inline-flex items-center justify-center w-full h-9 px-4 rounded-md bg-primary text-primary-foreground text-sm font-medium hover:bg-primary/90 transition-colors"
              >
                Zur Anmeldung
              </button>
            ) : (
              <a
                href="/.auth/logout"
                className="inline-flex items-center justify-center w-full h-9 px-4 rounded-md bg-primary text-primary-foreground text-sm font-medium hover:bg-primary/90 transition-colors"
              >
                Mit anderem Konto anmelden
              </a>
            )}
          </div>
        </div>

        <p className="text-center text-xs text-muted-foreground">
          &copy; 2026 envia Mitteldeutsche Energie AG &middot; Version 0.1
        </p>
      </div>
    </div>
  );
}
