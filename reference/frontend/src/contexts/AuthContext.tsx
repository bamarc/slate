import { createContext, useContext, useState, useEffect, type ReactNode } from "react";
import { isLocal } from "@/lib/env";
import { setAuthTokenProvider } from "@/api/fetcher";

export interface User {
  subject: string;
  name: string;
  email: string;
  roles: string[];
  permissions: string[];
}

export type LoginUserRole = string;

interface AuthContextType {
  user: User | null;
  login: (email: string, password: string, role: LoginUserRole) => Promise<boolean>;
  logout: () => void;
  isAuthenticated: boolean;
  isCheckingAuth: boolean;
  hasPermission: (permission: string) => boolean;
  defaultRoute: string;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export const rolePermissions: Record<string, string[]> = {
  user: ["User.Read"],
  admin: ["User.Read", "Administration.Read"],
};

const demoUserMapping: Record<string, { kid: string; name: string; email: string; roles: string[] }> = {
  user: { kid: "K99996", name: "Wagner, Max", email: "max.wagner@netz.de", roles: ["user"] },
  admin: { kid: "K99998", name: "Admin, Thomas", email: "admin@netz.de", roles: ["admin"] },
};

function parseUserInfo(data: { subject?: string; name?: string | null; email?: string | null; roles?: string[] }): User {
  const roles = data.roles || [];
  const permissions = new Set<string>();
  for (const role of roles) {
    for (const permission of rolePermissions[role] || []) permissions.add(permission);
  }
  return {
    subject: data.subject || "",
    name: data.name || "",
    email: data.email || "",
    roles,
    permissions: [...permissions],
  };
}

export function getDefaultVisibleRoute(hasPermission: (permission: string) => boolean): string {
  if (hasPermission("Administration.Read") || hasPermission("User.Read")) return "/";
  return "/forbidden";
}

setAuthTokenProvider(() => localStorage.getItem("auth_token"));

export function AuthProvider({ children }: { children: ReactNode }) {
  const [isCheckingAuth, setIsCheckingAuth] = useState(true);
  const [user, setUser] = useState<User | null>(() => {
    const stored = localStorage.getItem("user");
    const token = localStorage.getItem("auth_token");
    if (stored && (token || !isLocal())) return JSON.parse(stored);
    return null;
  });

  useEffect(() => {
    let mounted = true;
    const checkAuth = async () => {
      const localToken = localStorage.getItem("auth_token");
      if (isLocal() && !localToken) {
        if (mounted) {
          setUser(null);
          localStorage.removeItem("user");
          setIsCheckingAuth(false);
        }
        return;
      }
      try {
        const headers = new Headers({ Accept: "application/json" });
        if (localToken) headers.set("Authorization", `Bearer ${localToken}`);
        const res = await fetch("/api/v1/auth/me", {
          credentials: "include",
          headers,
        });
        if (res.status === 403) {
          window.location.href = "/forbidden";
          return;
        }
        if (!res.ok) {
          if (res.status === 401 && !isLocal()) {
            window.location.href = "/.auth/login/aad";
            return;
          }
          if (mounted) {
            setUser(null);
            localStorage.removeItem("user");
          }
          return;
        }
        const data = await res.json();
        const parsed = parseUserInfo(data);
        if (mounted) {
          setUser(parsed);
          localStorage.setItem("user", JSON.stringify(parsed));
        }
      } catch {
        if (mounted) {
          setUser(null);
          localStorage.removeItem("user");
        }
      } finally {
        if (mounted) setIsCheckingAuth(false);
      }
    };
    checkAuth();
    return () => {
      mounted = false;
    };
  }, []);

  const hasPermission = (permission: string): boolean =>
    user?.permissions.includes(permission) ?? false;
  const defaultRoute = getDefaultVisibleRoute(hasPermission);

  const login = async (_email: string, password: string, role: LoginUserRole): Promise<boolean> => {
    if (password && password !== "demo123") return false;
    try {
      const body = demoUserMapping[role] || demoUserMapping.user;
      const tokenRes = await fetch("/api/v1/auth/mock-token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!tokenRes.ok) return false;
      const { access_token } = await tokenRes.json();
      localStorage.setItem("auth_token", access_token);

      const meRes = await fetch("/api/v1/auth/me", {
        headers: {
          Authorization: `Bearer ${access_token}`,
          Accept: "application/json",
        },
      });
      if (!meRes.ok) {
        localStorage.removeItem("auth_token");
        return false;
      }
      const data = await meRes.json();
      const parsed = parseUserInfo(data);
      localStorage.setItem("user", JSON.stringify(parsed));
      setUser(parsed);
      return true;
    } catch {
      return false;
    }
  };

  const logout = () => {
    localStorage.removeItem("auth_token");
    localStorage.removeItem("user");
    setUser(null);
    if (!isLocal()) {
      window.location.href = "/.auth/logout";
    }
  };

  return (
    <AuthContext.Provider
      value={{
        user,
        login,
        logout,
        isAuthenticated: !!user,
        isCheckingAuth,
        hasPermission,
        defaultRoute,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error("useAuth must be used within an AuthProvider");
  }
  return context;
}
