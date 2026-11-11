import { cn } from '@/lib/utils';

/** The A icon on its own (transparent PNG in /public). */
export function BrandMark({ className, alt = 'AMS' }: { className?: string; alt?: string }) {
  return <img src="/logo-192.png" alt={alt} width={192} height={192} className={cn('h-8 w-8 select-none', className)} draggable={false} />;
}

/**
 * Full AMS lockup for the sign-in, sign-up and invite pages: A icon + "Agency Management" /
 * AMS / "Insurance Agency Management System". Stacks on narrow phones.
 */
export function BrandLockup({ className }: { className?: string }) {
  return (
    <div
      className={cn(
        'flex flex-col items-center gap-3 text-center min-[420px]:flex-row min-[420px]:gap-4 min-[420px]:text-left',
        className,
      )}
      style={{ fontFamily: "'Montserrat', 'Inter', sans-serif" }}
    >
      <BrandMark alt="" className="h-24 w-24 shrink-0 min-[420px]:h-28 min-[420px]:w-28" />
      <div className="leading-none">
        <div className="whitespace-nowrap text-2xl font-medium text-[#4a4a55] dark:text-slate-300">
          Agency Management
        </div>
        <div className="mt-1 text-7xl font-extrabold tracking-tight text-[#2a1f63] dark:text-indigo-200">AMS</div>
        <div className="mt-2 whitespace-nowrap text-[15px] font-medium text-[#4a4a55] dark:text-slate-400">
          Insurance Agency Management System
        </div>
      </div>
      <h1 className="sr-only">AMS — Insurance Agency Management System</h1>
    </div>
  );
}
