import { useCallback, useState } from "react";
import { useDropzone, type Accept, type FileRejection } from "react-dropzone";
import { Upload, X, FileIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";

export interface DropzoneProps {
  accept?: Accept;
  maxSize?: number;
  maxFiles?: number;
  multiple?: boolean;
  disabled?: boolean;
  onFilesAccepted?: (files: File[]) => void | Promise<void>;
  uploadProgress?: Record<string, number>;
  className?: string;
}

export function Dropzone({
  accept,
  maxSize = 10 * 1024 * 1024,
  maxFiles = 10,
  multiple = true,
  disabled,
  onFilesAccepted,
  uploadProgress,
  className,
}: DropzoneProps) {
  const [files, setFiles] = useState<File[]>([]);
  const [errors, setErrors] = useState<string[]>([]);

  const onDrop = useCallback(
    (accepted: File[], rejected: FileRejection[]) => {
      setErrors(rejected.flatMap((r) => r.errors.map((e) => `${r.file.name}: ${e.message}`)));
      setFiles((prev) => [...prev, ...accepted].slice(0, maxFiles));
      onFilesAccepted?.(accepted);
    },
    [maxFiles, onFilesAccepted],
  );

  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    onDrop,
    accept,
    maxSize,
    maxFiles,
    multiple,
    disabled,
  });

  const remove = (name: string) =>
    setFiles((prev) => prev.filter((f) => f.name !== name));

  return (
    <div className={cn("space-y-4", className)}>
      <div
        {...getRootProps()}
        className={cn(
          "border-2 border-dashed rounded-lg p-8 text-center cursor-pointer transition-colors",
          "hover:border-primary/50 hover:bg-accent/30",
          isDragActive && "border-primary bg-accent",
          disabled && "opacity-50 cursor-not-allowed",
        )}
      >
        <input {...getInputProps()} />
        <Upload className="mx-auto h-10 w-10 text-muted-foreground mb-3" />
        <p className="text-sm font-medium">
          {isDragActive ? "Drop the files here..." : "Drag & drop files or click to browse"}
        </p>
        <p className="text-xs text-muted-foreground mt-1">
          Max {maxFiles} files, up to {(maxSize / 1024 / 1024).toFixed(0)} MB each
        </p>
      </div>

      {errors.length > 0 && (
        <ul className="text-sm text-destructive space-y-1" role="alert">
          {errors.map((e, i) => (
            <li key={i}>{e}</li>
          ))}
        </ul>
      )}

      {files.length > 0 && (
        <ul className="space-y-2">
          {files.map((f) => (
            <li
              key={f.name}
              className="flex items-center gap-3 p-2 rounded-md border bg-card"
            >
              <FileIcon className="h-4 w-4 text-muted-foreground" />
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium truncate">{f.name}</p>
                <p className="text-xs text-muted-foreground">
                  {(f.size / 1024).toFixed(1)} KB
                </p>
                {uploadProgress?.[f.name] !== undefined && (
                  <Progress value={uploadProgress[f.name]} className="h-1 mt-1" />
                )}
              </div>
              <Button
                variant="ghost"
                size="icon"
                onClick={() => remove(f.name)}
                aria-label={`Remove ${f.name}`}
              >
                <X className="h-4 w-4" />
              </Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
