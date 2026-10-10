import { useEffect, useState, type ReactNode } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useNavigate, useLocation } from "react-router-dom";
import { isLocal } from "@/lib/env";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { LogOut, Settings, HelpCircle, Palette, type LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";

export interface NavItem {
  path: string;
  label: string;
  icon: LucideIcon;
  requiredPermission?: string;
  requiredPermissions?: string[];
  disabled?: boolean;
}

interface AppLayoutProps {
  children: ReactNode;
  appName?: string;
  appDescription?: string;
  logo?: ReactNode;
  navigationItems?: NavItem[];
  userMenuExtraItems?: ReactNode;
}

export function AppLayout({
  children,
  appName = "Fullstack Template",
  appDescription = "React + Vite + Tailwind + FastAPI",
  logo,
  navigationItems = [],
  userMenuExtraItems,
}: AppLayoutProps) {
  const { user, logout, hasPermission } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const [designMode, setDesignMode] = useState<"standard" | "envia">(
    () => (localStorage.getItem("fullstack-design") === "standard" ? "standard" : "envia"),
  );

  useEffect(() => {
    document.documentElement.dataset.design = designMode;
  }, [designMode]);

  if (!user) {
    return <>{children}</>;
  }

  const filteredNavItems = navigationItems.filter((item) => {
    if (item.requiredPermissions?.length) return item.requiredPermissions.some(hasPermission);
    return !item.requiredPermission || hasPermission(item.requiredPermission);
  });

  const handleLogout = () => {
    logout();
    if (isLocal()) {
      navigate("/login");
    }
  };

  const getRoleBadge = (roles: string[]) => {
    const labels: Record<string, string> = {
      user: "Benutzer",
      admin: "Administrator",
      antragsteller: "Antragsteller",
      schaltleitung: "Schaltleitung",
      betrachter: "Betrachter",
    };
    const primary = roles[0] || "user";
    return labels[primary] || primary;
  };

  return (
    <div className="min-h-screen flex flex-col bg-background">
      <header className="sticky top-0 z-50 w-full border-b bg-card/95 backdrop-blur supports-[backdrop-filter]:bg-card/80">
        <div className="container mx-auto px-4 md:px-6 flex h-16 items-center justify-between">
          <div className="flex items-center gap-6">
            <div className="flex items-center gap-2">
              {logo || (
                <div className="w-10 h-10 rounded-lg bg-primary flex items-center justify-center">
                  <span className="text-primary-foreground font-bold text-lg">T</span>
                </div>
              )}
              <div>
                <h1 className="font-bold text-lg leading-none">{appName}</h1>
                <span className="text-xs text-muted-foreground">{appDescription}</span>
              </div>
            </div>

            {filteredNavItems.length > 0 && (
              <nav className="hidden md:flex items-center gap-1">
                {filteredNavItems.map((item) => {
                  const Icon = item.icon;
                    const isActive = item.path === "/"
                      ? location.pathname === "/"
                      : location.pathname === item.path || location.pathname.startsWith(`${item.path}/`);

                  return (
                    <Button
                      key={item.path}
                      variant="ghost"
                      size="sm"
                      onClick={() => !item.disabled && navigate(item.path)}
                      disabled={item.disabled}
                      className={cn(
                        "gap-2",
                        isActive && "bg-secondary text-secondary-foreground shadow-none",
                        item.disabled && "opacity-50 cursor-not-allowed",
                      )}
                    >
                      <Icon className="w-4 h-4" />
                      {item.label}
                    </Button>
                  );
                })}
              </nav>
            )}
          </div>

          <div className="flex items-center gap-3">
            <div className="hidden items-center gap-1 rounded-lg border bg-background p-1 sm:flex" role="group" aria-label="Design auswählen">
              <Palette className="mx-1 h-4 w-4 text-primary" aria-hidden="true" />
              {(["envia", "standard"] as const).map((mode) => (
                <button
                  className={cn("rounded-md px-2 py-1 text-xs font-medium", designMode === mode && "bg-secondary")}
                  key={mode}
                  type="button"
                  aria-pressed={designMode === mode}
                  onClick={() => {
                    setDesignMode(mode);
                    localStorage.setItem("fullstack-design", mode);
                  }}
                >
                  {mode === "envia" ? "envia" : "Standard"}
                </button>
              ))}
            </div>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button
                  variant="ghost"
                  className="flex items-center gap-2 px-2 group hover:bg-secondary hover:text-foreground focus-visible:ring-0 focus-visible:ring-offset-0 focus:ring-0 focus:ring-offset-0 outline-none shadow-none border-none"
                >
                  <Avatar className="h-8 w-8">
                    <AvatarFallback className="bg-primary text-primary-foreground text-sm">
                      {user.name
                        .split(" ")
                        .map((n) => n[0])
                        .join("") || user.subject.slice(0, 2).toUpperCase()}
                    </AvatarFallback>
                  </Avatar>
                  <div className="hidden sm:block text-left">
                    <p className="text-sm font-medium leading-none group-hover:text-foreground">
                      {user.name}
                    </p>
                    <p className="text-xs text-muted-foreground group-hover:text-foreground/80">
                      {getRoleBadge(user.roles)}
                    </p>
                  </div>
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-56 bg-popover">
                <DropdownMenuLabel>
                  <div className="flex flex-col space-y-1">
                    <p className="text-sm font-medium">{user.name}</p>
                    <p className="text-xs text-muted-foreground font-mono">{user.subject}</p>
                  </div>
                </DropdownMenuLabel>
                <DropdownMenuSeparator />
                {userMenuExtraItems}
                <DropdownMenuItem onClick={() => navigate("/settings")}>
                  <Settings className="mr-2 h-4 w-4" />
                  Einstellungen
                </DropdownMenuItem>
                <DropdownMenuItem onClick={() => navigate("/help")}>
                  <HelpCircle className="mr-2 h-4 w-4" />
                  Hilfe
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem onClick={handleLogout} className="text-destructive">
                  <LogOut className="mr-2 h-4 w-4" />
                  Abmelden
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>
      </header>

      {filteredNavItems.length > 0 && (
        <nav className="md:hidden sticky top-16 z-40 w-full border-b bg-card overflow-x-auto">
          <div className="flex p-2 gap-1">
            {filteredNavItems.map((item) => {
              const Icon = item.icon;
              const isActive = item.path === "/"
                ? location.pathname === "/"
                : location.pathname === item.path || location.pathname.startsWith(`${item.path}/`);

              return (
                <Button
                  key={item.path}
                  variant="ghost"
                  size="sm"
                  onClick={() => !item.disabled && navigate(item.path)}
                  disabled={item.disabled}
                  className={cn(
                    "gap-1 whitespace-nowrap",
                    isActive && "bg-secondary text-secondary-foreground shadow-none",
                    item.disabled && "opacity-50 cursor-not-allowed",
                  )}
                >
                  <Icon className="w-4 h-4" />
                  {item.label}
                </Button>
              );
            })}
          </div>
        </nav>
      )}

      <main className="container mx-auto px-4 md:px-6 flex-1 py-6">
        {children}
      </main>
    </div>
  );
}
