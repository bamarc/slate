import * as React from "react";
import { format } from "date-fns";
import { de } from "date-fns/locale";
import { Calendar as CalendarIcon } from "lucide-react";
import type { DateRange } from "react-day-picker";
import { Button } from "@/components/ui/button";
import { Calendar } from "@/components/ui/calendar";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { QUICK_DATE_PRESETS, resolvePresetRange, type QuickDatePresetKey } from "@/lib/date-presets";
import { cn } from "@/lib/utils";

export interface DatePickerWithRangeProps extends React.HTMLAttributes<HTMLDivElement> {
  date: DateRange | undefined;
  setDate: (date: DateRange | undefined) => void;
}

export function DatePickerWithRange({ className, date, setDate }: DatePickerWithRangeProps) {
  const [currentMonth, setCurrentMonth] = React.useState(date?.from ?? new Date());
  const handlePresetSelect = (preset: QuickDatePresetKey) => {
    const range = resolvePresetRange(new Date(), preset);
    setDate(range);
    if (range?.from) setCurrentMonth(range.from);
  };
  return <div className={cn("grid gap-2", className)}>
    <Popover><PopoverTrigger asChild><Button className={cn("w-full justify-start text-left font-normal", !date && "text-muted-foreground")} variant="outline"><CalendarIcon className="mr-2 h-4 w-4" />{date?.from ? date.to ? `${format(date.from, "dd.MM.y", { locale: de })} - ${format(date.to, "dd.MM.y", { locale: de })}` : format(date.from, "dd.MM.y", { locale: de }) : "Zeitraum wählen"}</Button></PopoverTrigger>
      <PopoverContent align="start" className="flex w-auto p-0"><div className="flex min-w-[140px] flex-col gap-1 border-r p-3"><span className="mb-1 px-2 text-xs font-semibold text-muted-foreground">Vorlagen</span>{QUICK_DATE_PRESETS.map((preset) => <Button className="justify-start text-sm font-normal" key={preset.key} onClick={() => handlePresetSelect(preset.key)} variant="ghost">{preset.label}</Button>)}</div><Calendar autoFocus captionLayout="dropdown-months" fromYear={new Date().getFullYear() - 2} initialFocus locale={de} mode="range" month={currentMonth} numberOfMonths={2} onMonthChange={setCurrentMonth} onSelect={setDate} selected={date} toYear={new Date().getFullYear() + 5} /></PopoverContent>
    </Popover>
  </div>;
}
