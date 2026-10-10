import { Navigate, useNavigate } from "react-router-dom";
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { useAuth } from "@/contexts/AuthContext";
import { ChevronRight, type LucideIcon } from "lucide-react";

export interface AdminTile {
  id: string;
  title: string;
  description: string;
  icon: LucideIcon;
  path: string;
}

interface AdminProps {
  tiles?: AdminTile[];
}

const defaultTiles: AdminTile[] = [
  {
    id: "admin-card-settings",
    title: "Einstellungen",
    description: "Allgemeine Systemeinstellungen und Konfiguration.",
    icon: ChevronRight,
    path: "/settings",
  },
];

const Admin = ({ tiles = defaultTiles }: AdminProps) => {
  const navigate = useNavigate();
  const { hasPermission } = useAuth();

  if (!hasPermission("Administration.Read")) {
    return <Navigate to="/forbidden" replace />;
  }

  return (
    <div className="space-y-6">
      <header>
        <h1 className="font-display text-3xl lg:text-4xl font-extrabold text-primary">
          Administration
        </h1>
        <p className="mt-1.5 text-sm text-muted-foreground">
          Zentrale Admin-Funktionen.
        </p>
      </header>

      <section className="grid gap-4 md:grid-cols-2 auto-rows-fr">
        {tiles.map((tile) => {
          const Icon = tile.icon;
          return (
            <Card
              key={tile.id}
              id={tile.id}
              onClick={() => navigate(tile.path)}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  navigate(tile.path);
                }
              }}
              role="button"
              tabIndex={0}
              className="group cursor-pointer select-none border-border/70 transition-all duration-200 hover:border-accent/50 hover:shadow-[var(--shadow-card-hover)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 h-full"
            >
              <CardHeader className="flex flex-row items-start space-x-4 space-y-0 h-full">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-accent/10 text-accent transition-colors group-hover:bg-accent/20">
                  <Icon className="h-5 w-5" />
                </div>
                <div className="flex-1 space-y-1.5 min-w-0">
                  <CardTitle className="text-lg text-primary group-hover:text-accent transition-colors">
                    {tile.title}
                  </CardTitle>
                  <CardDescription>{tile.description}</CardDescription>
                </div>
                <div className="flex h-10 shrink-0 items-center justify-center">
                  <ChevronRight className="h-5 w-5 text-muted-foreground/60 transition-all duration-200 translate-x-[-4px] opacity-0 group-hover:translate-x-0 group-hover:opacity-100 group-hover:text-accent" />
                </div>
              </CardHeader>
            </Card>
          );
        })}
      </section>
    </div>
  );
};

export default Admin;
