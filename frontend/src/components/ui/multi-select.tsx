import * as React from "react";
import { ChevronDown, Filter } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { cn } from "@/lib/utils";

export interface MultiSelectOption { label: string; value: string; }
export interface MultiSelectProps {
  options: MultiSelectOption[];
  value: string[];
  onChange: (value: string[]) => void;
  placeholder?: string;
  emptyLabel?: string;
  className?: string;
}

export function MultiSelect({ options, value, onChange, placeholder = "Ausgewählt", emptyLabel = "Alle", className }: MultiSelectProps) {
  const [open, setOpen] = React.useState(false);
  const label = value.length === 0 ? emptyLabel : value.length === 1 ? options.find((option) => option.value === value[0])?.label : `${placeholder} (${value.length})`;
  const toggle = (option: string) => onChange(value.includes(option) ? value.filter((item) => item !== option) : [...value, option]);
  return <Popover open={open} onOpenChange={setOpen}>
    <PopoverTrigger asChild><Button aria-expanded={open} className={cn("w-full justify-between bg-background px-3 font-normal", className)} role="combobox" variant="outline"><span className="flex min-w-0 items-center gap-2 truncate"><Filter className="h-3 w-3 text-muted-foreground" />{label}</span><ChevronDown className="h-4 w-4 opacity-50" /></Button></PopoverTrigger>
    <PopoverContent align="start" className="w-56 p-2"><div className="max-h-60 space-y-1 overflow-y-auto">{options.map((option) => <div aria-selected={value.includes(option.value)} className="flex cursor-pointer items-center gap-2 rounded-sm px-2 py-1.5 hover:bg-accent" key={option.value} onClick={() => toggle(option.value)} role="option" tabIndex={0} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle(option.value); } }}><Checkbox checked={value.includes(option.value)} onCheckedChange={() => toggle(option.value)} onClick={(event) => event.stopPropagation()} /><span className="text-sm">{option.label}</span></div>)}</div></PopoverContent>
  </Popover>;
}
