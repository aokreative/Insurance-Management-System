import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';

export function StatCard({ 
  title, 
  value, 
  subtitle, 
  icon: Icon,
  loading = false,
  trend,
  className
}: { 
  title: string; 
  value: string | number; 
  subtitle?: string; 
  icon?: React.ElementType;
  loading?: boolean;
  trend?: { value: number; label: string };
  className?: string;
}) {
  return (
    <Card className={className}>
      <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground">{title}</CardTitle>
        {Icon && <Icon className="h-4 w-4 text-muted-foreground" />}
      </CardHeader>
      <CardContent>
        {loading ? (
          <Skeleton className="h-8 w-24 mb-1" />
        ) : (
          <div className="text-2xl font-bold">{value}</div>
        )}
        
        {loading ? (
          <Skeleton className="h-4 w-32 mt-1" />
        ) : (
          <div className="flex items-center text-xs text-muted-foreground mt-1 gap-2">
            {trend && (
              <span className={`font-medium ${trend.value >= 0 ? 'text-emerald-600 dark:text-emerald-500' : 'text-red-600 dark:text-red-500'}`}>
                {trend.value >= 0 ? '+' : ''}{trend.value}%
              </span>
            )}
            <span>{subtitle}</span>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
