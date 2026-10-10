import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "@/contexts/AuthContext";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { AlertCircle } from "lucide-react";
import { toast } from "sonner";
import { getErrorMessage } from "@/lib/utils";

const roleDescriptions = [
  { value: "user", label: "Benutzer", description: "Standard-Benutzerzugriff" },
  { value: "admin", label: "Administrator", description: "Voller Systemzugriff" },
];

export default function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("demo123");
  const [role, setRole] = useState("user");
  const [isLoading, setIsLoading] = useState(false);
  const { login } = useAuth();
  const navigate = useNavigate();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsLoading(true);
    try {
      const success = await login(email, password, role);
      if (success) {
        navigate("/");
      } else {
        toast.error("Anmeldung fehlgeschlagen");
      }
    } catch (error) {
      toast.error("Ein Fehler ist aufgetreten", { description: getErrorMessage(error) });
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-background flex flex-col items-center justify-center p-4">
      <div className="absolute inset-0 bg-[linear-gradient(to_right,hsl(var(--border))_1px,transparent_1px),linear-gradient(to_bottom,hsl(var(--border))_1px,transparent_1px)] bg-[size:4rem_4rem] [mask-image:radial-gradient(ellipse_60%_50%_at_50%_0%,#000_70%,transparent_110%)] -z-10" />

      <div className="w-full max-w-md space-y-6 animate-slide-up">
        <div className="flex flex-col items-center gap-4">
          <div className="w-16 h-16 rounded-2xl bg-primary flex items-center justify-center shadow-lg">
            <span className="text-primary-foreground font-bold text-3xl">T</span>
          </div>
          <div className="text-center">
            <h1 className="text-3xl font-bold">Fullstack Template</h1>
            <p className="text-muted-foreground mt-1">React + Vite + Tailwind + FastAPI</p>
          </div>
        </div>

        <Card className="border-0 shadow-lg">
          <CardHeader>
            <CardTitle>Anmelden</CardTitle>
            <CardDescription>Wähle Deine Rolle für den Demo-Zugang</CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="role">Benutzerrolle</Label>
                <Select value={role} onValueChange={setRole}>
                  <SelectTrigger className="bg-background">
                    <SelectValue placeholder="Rolle auswählen" />
                  </SelectTrigger>
                  <SelectContent className="bg-popover">
                    {roleDescriptions.map((r) => (
                      <SelectItem key={r.value} value={r.value}>
                        <div className="flex items-center gap-2">
                          <div>
                            <span className="font-medium">{r.label}</span>
                            <span className="text-xs text-muted-foreground ml-2">
                              – {r.description}
                            </span>
                          </div>
                        </div>
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-2">
                <Label htmlFor="email">E-Mail</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="name@netz.de"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="password">Passwort</Label>
                <Input
                  id="password"
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
              </div>

              <Button type="submit" className="w-full" disabled={isLoading}>
                {isLoading ? "Wird angemeldet..." : "Anmelden"}
              </Button>
            </form>

            <div className="mt-6 p-3 bg-muted rounded-lg">
              <div className="flex items-start gap-2">
                <AlertCircle className="w-4 h-4 text-muted-foreground mt-0.5" />
                <div className="text-xs text-muted-foreground">
                  <p className="font-medium mb-1">Demo-Zugang</p>
                  <p>
                    Passwort: <code className="bg-background px-1 py-0.5 rounded">demo123</code>
                  </p>
                  <p>Die E-Mail wird automatisch basierend auf der Rolle gesetzt.</p>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        <p className="text-center text-xs text-muted-foreground">
          &copy; 2026 envia Mitteldeutsche Energie AG &middot; Version 0.1
        </p>
      </div>
    </div>
  );
}
