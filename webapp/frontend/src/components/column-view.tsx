import { type ReactNode, useState, useCallback, useRef, useEffect } from 'react';
import { Button } from '@/components/ui/button';
import { ChevronLeft } from 'lucide-react';

interface Column {
  key: string;
  title?: string;
  content: ReactNode | null;
  width?: string;
  minWidth?: number;
}

interface ColumnViewProps {
  columns: Column[];
  onBack?: () => void;
}

/**
 * Column View — hierarchical navigation like macOS Finder.
 * Desktop: side-by-side columns with draggable resize handle.
 * Mobile: shows only the last (deepest) column with back button.
 */
export function ColumnView({ columns, onBack }: ColumnViewProps) {
  // All hooks MUST be called before any conditional return
  const [detailWidth, setDetailWidth] = useState<number | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    dragging.current = true;
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  }, []);

  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (!dragging.current || !containerRef.current) return;
      const rect = containerRef.current.getBoundingClientRect();
      const rightEdge = rect.right;
      const newWidth = Math.max(280, Math.min(rightEdge - e.clientX, rect.width * 0.7));
      setDetailWidth(newWidth);
    };
    const handleMouseUp = () => {
      dragging.current = false;
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    };
    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);
    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };
  }, []);

  // Reset detail width when columns change
  useEffect(() => {
    if (columns.length <= 1) setDetailWidth(null);
  }, [columns.length]);

  if (columns.length === 0) return null;

  const lastCol = columns.at(-1)!;
  const showBack = columns.length > 1 && onBack;

  return (
    <>
      {/* Desktop: side-by-side columns with resize handle */}
      <div ref={containerRef} className="hidden md:flex h-full">
        {columns.map((col, i) => {
          const isLast = i === columns.length - 1;
          const colWidth = detailWidth ? `${detailWidth}px` : (col.width || '400px');
          return (
            <div key={col.key} className="contents">
              <div
                className="flex flex-col min-w-0 overflow-hidden"
                style={{
                  width: i === 0 ? undefined : colWidth,
                  flex: i === 0 ? '1 1 auto' : `0 0 ${colWidth}`,
                }}
              >
                {col.content}
              </div>
              {/* Resize handle between columns */}
              {!isLast && (
                <div
                  role="separator"
                  tabIndex={0}
                  aria-label="Resize pane"
                  className="flex-shrink-0 w-1 cursor-col-resize bg-border hover:bg-primary/40 transition-colors relative"
                  onMouseDown={handleMouseDown}
                >
                  <div className="absolute inset-y-0 -left-1 -right-1" />
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Mobile: single column with back */}
      <div className="flex flex-col h-full md:hidden">
        {showBack && (
          <div className="flex items-center gap-1 px-2 pt-2">
            <Button variant="ghost" size="sm" className="h-7 gap-1 text-xs" onClick={onBack}>
              <ChevronLeft className="w-4 h-4" />
              Back
            </Button>
            {lastCol.title && (
              <span className="text-sm font-medium truncate">{lastCol.title}</span>
            )}
          </div>
        )}
        <div className="flex-1 min-h-0 overflow-hidden">
          {lastCol.content}
        </div>
      </div>
    </>
  );
}
