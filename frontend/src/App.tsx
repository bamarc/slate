import { QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { queryClient } from "@/lib/queryClient";
import { AuthProvider, useAuth } from "@/contexts/AuthContext";
import { AppLayout } from "@/components/AppLayout";
import { TestSystemDisclaimerFrame } from "@/components/TestSystemDisclaimerFrame";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { isLocal } from "@/lib/env";
import { Search, Zap, Sparkles } from "lucide-react";

import Index from "./pages/Index";
import NotFound from "./pages/NotFound";
import Admin from "./pages/Admin";
import Forbidden from "./pages/Forbidden";
import Login from "./pages/Login";
import ShowcasePage from "./pages/ShowcasePage";

const navigationItems = [
  { path: "/", label: "Dashboard", icon: Search, requiredPermission: "User.Read" },
  { path: "/showcase", label: "Showcase", icon: Sparkles, requiredPermission: "User.Read" },
  { path: "/admin", label: "Admin", icon: Zap, requiredPermission: "Administration.Read" },
];

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { isAuthenticated } = useAuth();
  if (!isAuthenticated) {
    return isLocal() ? <Navigate to="/login" replace /> : null;
  }
  return <AppLayout navigationItems={navigationItems}>{children}</AppLayout>;
}

function PermissionRoute({
  children,
  permission,
  anyPermission,
}: {
  children: React.ReactNode;
  permission?: string;
  anyPermission?: string[];
}) {
  const { hasPermission } = useAuth();
  const allowed = anyPermission?.length
    ? anyPermission.some(hasPermission)
    : permission
      ? hasPermission(permission)
      : true;
  if (!allowed) {
    return <Navigate to="/forbidden" replace />;
  }
  return <>{children}</>;
}

function AppRoutes() {
  const { isAuthenticated, isCheckingAuth } = useAuth();

  if (isCheckingAuth) {
    return <div className="flex h-screen w-screen items-center justify-center">Lädt...</div>;
  }

  return (
    <Routes>
      <Route path="/forbidden" element={<Forbidden />} />
      <Route
        path="/showcase"
        element={
          <ProtectedRoute>
            <ShowcasePage />
          </ProtectedRoute>
        }
      />
      {isLocal() && (
        <Route
          path="/login"
          element={isAuthenticated ? <Navigate to="/" replace /> : <Login />}
        />
      )}
      <Route
        path="/"
        element={
          <ProtectedRoute>
            <Index />
          </ProtectedRoute>
        }
      />
      <Route
        path="/admin"
        element={
          <ProtectedRoute>
            <PermissionRoute permission="Administration.Read">
              <Admin />
            </PermissionRoute>
          </ProtectedRoute>
        }
      />
      <Route path="*" element={<NotFound />} />
    </Routes>
  );
}

const App = () => (
  <QueryClientProvider client={queryClient}>
    <AuthProvider>
      <TooltipProvider>
        <TestSystemDisclaimerFrame>
          <Sonner />
          <BrowserRouter>
            <ErrorBoundary>
              <AppRoutes />
            </ErrorBoundary>
          </BrowserRouter>
        </TestSystemDisclaimerFrame>
      </TooltipProvider>
    </AuthProvider>
  </QueryClientProvider>
);

export default App;
