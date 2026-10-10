import { useState } from "react";
import { format } from "date-fns";
import { CalendarIcon } from "lucide-react";
import { type DateRange } from "react-day-picker";
import { Calendar } from "@/components/ui/calendar";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { cn } from "@/lib/utils";
import { QUICK_DATE_PRESETS, resolvePresetRange } from "@/lib/date-presets";
import type { QuickDatePresetKey } from "@/lib/date-presets";

export interface DatePickerProps {
  value?: Date;
  onChange?: (date: Date | undefined) => void;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
}

export function DatePicker({
  value,
  onChange,
  placeholder = "Pick a date",
  disabled,
  className,
}: DatePickerProps) {
  const [open, setOpen] = useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          disabled={disabled}
          className={cn(
            "justify-start text-left font-normal",
            !value && "text-muted-foreground",
            className,
          )}
        >
          <CalendarIcon className="mr-2 h-4 w-4" />
          {value ? format(value, "PPP") : placeholder}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-auto p-0" align="start">
        <Calendar
          mode="single"
          selected={value}
          onSelect={(d) => {
            onChange?.(d);
            setOpen(false);
          }}
          autoFocus
        />
      </PopoverContent>
    </Popover>
  );
}

export interface DateRangePickerProps {
  value?: DateRange;
  onChange?: (range: DateRange | undefined) => void;
  placeholder?: string;
  className?: string;
}

export function DateRangePicker({
  value,
  onChange,
  placeholder = "Pick a date range",
  className,
}: DateRangePickerProps) {
  const [selectedPreset, setSelectedPreset] = useState<QuickDatePresetKey | null>(null);

  const handlePresetClick = (key: QuickDatePresetKey) => {
    setSelectedPreset(key);
    const range = resolvePresetRange(new Date(), key);
    onChange?.(range);
  };

  const handleCalendarSelect = (range: DateRange | undefined) => {
    setSelectedPreset(null);
    onChange?.(range);
  };

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          className={cn(
            "justify-start text-left font-normal",
            !value && "text-muted-foreground",
            className,
          )}
        >
          <CalendarIcon className="mr-2 h-4 w-4" />
          {value?.from ? (
            value.to ? (
              <>
                {format(value.from, "LLL d, y")} – {format(value.to, "LLL d, y")}
              </>
            ) : (
              format(value.from, "LLL d, y")
            )
          ) : (
            placeholder
          )}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-auto p-0" align="start">
        <div className="flex">
          <div className="flex flex-col gap-1 p-2 border-r min-w-[130px]">
            <p className="text-xs font-medium text-muted-foreground px-2 py-1">Schnellauswahl</p>
            {QUICK_DATE_PRESETS.map((preset) => (
              <Button
                key={preset.key}
                variant={selectedPreset === preset.key ? "secondary" : "ghost"}
                size="sm"
                onClick={() => handlePresetClick(preset.key)}
                className="justify-start text-xs h-7"
              >
                {preset.label}
              </Button>
            ))}
          </div>
          <Calendar
            mode="range"
            selected={value}
            onSelect={handleCalendarSelect}
            numberOfMonths={2}
            autoFocus
          />
        </div>
      </PopoverContent>
    </Popover>
  );
}
