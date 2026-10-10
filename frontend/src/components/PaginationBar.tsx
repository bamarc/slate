import { useMemo } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
} from "@/components/ui/pagination";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

interface PaginationBarProps {
  page: number;
  totalPages: number;
  pageSize: number;
  totalItems: number;
  pageSizeOptions?: number[];
  onPageChange: (page: number) => void;
  onPageSizeChange: (pageSize: number) => void;
  isNarrow?: boolean;
}

export function PaginationBar({
  page,
  totalPages,
  pageSize,
  totalItems,
  pageSizeOptions = [5, 10, 20, 50],
  onPageChange,
  onPageSizeChange,
  isNarrow = false,
}: PaginationBarProps) {
  const startIdx = totalItems === 0 ? 0 : (page - 1) * pageSize + 1;
  const endIdx = totalItems === 0 ? 0 : Math.min(page * pageSize, totalItems);

  const pageNumbers = useMemo(() => {
    if (totalPages <= 5) {
      return Array.from({ length: totalPages }, (_, i) => i + 1);
    }

    const leftSiblingIndex = Math.max(page - 1, 1);
    const rightSiblingIndex = Math.min(page + 1, totalPages);

    const shouldShowLeftEllipsis = leftSiblingIndex > 2;
    const shouldShowRightEllipsis = rightSiblingIndex < totalPages - 1;

    if (!shouldShowLeftEllipsis && shouldShowRightEllipsis) {
      const itemCount = 4;
      const leftRange = Array.from({ length: itemCount }, (_, i) => i + 1);
      return [...leftRange, "ellipsis" as const, totalPages];
    }

    if (shouldShowLeftEllipsis && !shouldShowRightEllipsis) {
      const itemCount = 4;
      const rightRange = Array.from(
        { length: itemCount },
        (_, i) => totalPages - itemCount + i + 1,
      );
      return [1, "ellipsis" as const, ...rightRange];
    }

    if (shouldShowLeftEllipsis && shouldShowRightEllipsis) {
      const middleRange = [page - 1, page, page + 1];
      return [1, "ellipsis" as const, ...middleRange, "ellipsis" as const, totalPages];
    }

    return Array.from({ length: totalPages }, (_, i) => i + 1);
  }, [page, totalPages]);

  return (
    <div
      className={
        isNarrow
          ? "mt-8 w-full flex flex-col items-center gap-y-3"
          : "mt-8 w-full flex flex-col items-center gap-y-3 sm:flex-row sm:flex-wrap sm:items-center sm:gap-x-4 sm:gap-y-3 lg:grid lg:grid-cols-3 lg:gap-x-4 lg:gap-y-0"
      }
    >
      <div
        className={
          isNarrow
            ? "flex items-center justify-center gap-2"
            : "flex items-center justify-center gap-2 sm:justify-start sm:shrink-0"
        }
      >
        <span className="text-sm text-muted-foreground whitespace-nowrap">Einträge pro Seite:</span>
        <Select
          value={String(pageSize)}
          onValueChange={(val) => onPageSizeChange(Number(val))}
        >
          <SelectTrigger className="h-8 w-[70px] bg-background">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {pageSizeOptions.map((option) => (
              <SelectItem key={option} value={String(option)}>
                {option}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div
        className={
          isNarrow
            ? "flex w-full justify-center"
            : "flex w-full justify-center sm:flex-1 lg:flex-none lg:w-full lg:justify-center"
        }
      >
        <Pagination className="mx-0 w-auto">
          <PaginationContent>
            <PaginationItem>
              <Button
                size="icon"
                variant="ghost"
                className="h-8 w-8"
                disabled={page === 1}
                onClick={() => onPageChange(Math.max(1, page - 1))}
                aria-label="Vorherige Seite"
              >
                <ChevronLeft className="h-4 w-4" />
              </Button>
            </PaginationItem>

            {pageNumbers.map((num, i) => (
              <PaginationItem key={i}>
                {num === "ellipsis" ? (
                  <PaginationEllipsis className="h-8 w-8" />
                ) : (
                  <Button
                    size="icon"
                    variant={num === page ? "default" : "ghost"}
                    onClick={() => onPageChange(num)}
                    className="h-8 w-8"
                  >
                    {num}
                  </Button>
                )}
              </PaginationItem>
            ))}

            <PaginationItem>
              <Button
                size="icon"
                variant="ghost"
                className="h-8 w-8"
                disabled={page === totalPages}
                onClick={() => onPageChange(Math.min(totalPages, page + 1))}
                aria-label="Nächste Seite"
              >
                <ChevronRight className="h-4 w-4" />
              </Button>
            </PaginationItem>
          </PaginationContent>
        </Pagination>
      </div>

      <div
        className={
          isNarrow
            ? "text-sm text-muted-foreground text-center w-full"
            : "text-sm text-muted-foreground text-center w-full sm:w-full lg:w-auto lg:text-right"
        }
      >
        Zeige {startIdx}–{endIdx} von {totalItems} Ergebnissen an
      </div>
    </div>
  );
}
