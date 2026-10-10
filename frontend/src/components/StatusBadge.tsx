import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import {
  FileEdit,
  Send,
  CheckCircle2,
  XCircle,
  ClipboardCheck,
  Trash2,
  Ban,
  AlertTriangle,
} from "lucide-react";
import type { ComponentType } from "react";

export interface StatusConfig {
  bgClass: string;
  textClass: string;
  icon: ComponentType<{ className?: string }>;
  label: string;
}

interface StatusBadgeProps {
  config: StatusConfig;
  className?: string;
  showIcon?: boolean;
}

export function StatusBadge({ config, className, showIcon = true }: StatusBadgeProps) {
  const Icon = config.icon;
  return (
    <Badge
      variant="secondary"
      className={cn("border-transparent", config.bgClass, config.textClass, className)}
    >
      {showIcon && <Icon className="w-3 h-3 mr-1" />}
      {config.label}
    </Badge>
  );
}

export const statusIconMap = {
  FileEdit,
  Send,
  CheckCircle2,
  XCircle,
  ClipboardCheck,
  Trash2,
  Ban,
  AlertTriangle,
};
