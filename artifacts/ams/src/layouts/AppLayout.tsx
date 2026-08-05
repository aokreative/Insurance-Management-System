import React from 'react';
import { Link, useLocation } from 'wouter';
import { useAuth } from '@/contexts/AuthContext';
import { 
  LayoutDashboard, 
  Users, 
  FileText, 
  DollarSign, 
  RefreshCcw, 
  Building2, 
  Tag, 
  Settings,
  LogOut,
  Menu,
  BarChart2
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { addDays, startOfDay } from 'date-fns';
import { Badge } from '@/components/ui/badge';
import { Avatar, AvatarFallback } from '@/components/ui/avatar';
import { 
  Sheet,
  SheetContent,
  SheetTrigger,
} from "@/components/ui/sheet";

export function AppLayout({ children }: { children: React.ReactNode }) {
  const { agency, profile, signOut, session } = useAuth();
  const [location] = useLocation();
  const [isMobileMenuOpen, setIsMobileMenuOpen] = React.useState(false);

  // Get count of upcoming renewals in 30 days
  const { data: renewalsCount = 0 } = useQuery({
    queryKey: ['renewals-count', agency?.id],
    queryFn: async () => {
      const today = startOfDay(new Date()).toISOString();
      const in30Days = addDays(new Date(), 30).toISOString();
      
      const { count, error } = await supabase
        .from('policies')
        .select('*', { count: 'exact', head: true })
        .eq('agency_id', agency?.id)
        .eq('status', 'active')
        .gte('expiry_date', today)
        .lte('expiry_date', in30Days);
        
      if (error) throw error;
      return count || 0;
    },
    enabled: !!agency?.id && !!session,
  });

  const navItems = [
    { name: 'Dashboard', path: '/dashboard', icon: LayoutDashboard },
    { name: 'Clients', path: '/clients', icon: Users },
    { name: 'Policies', path: '/policies', icon: FileText },
    { name: 'Commissions', path: '/commissions', icon: DollarSign },
    { 
      name: 'Renewals', 
      path: '/renewals', 
      icon: RefreshCcw,
      badge: renewalsCount > 0 ? renewalsCount : undefined
    },
    { name: 'Reports', path: '/reports', icon: BarChart2 },
    { name: 'Insurers', path: '/insurers', icon: Building2 },
    { name: 'Product Lines', path: '/product-lines', icon: Tag },
    { name: 'Settings', path: '/settings', icon: Settings },
  ];

  const NavLinks = () => (
    <div className="space-y-1">
      {navItems.map((item) => {
        const isActive = location === item.path || location.startsWith(item.path + '/');
        const Icon = item.icon;
        
        return (
          <Link key={item.path} href={item.path} onClick={() => setIsMobileMenuOpen(false)}>
            <div
              className={`flex items-center gap-3 px-3 py-2 rounded-md transition-colors cursor-pointer text-sm font-medium ${
                isActive 
                  ? 'bg-sidebar-accent text-sidebar-accent-foreground' 
                  : 'text-sidebar-foreground/80 hover:bg-sidebar-accent/50 hover:text-sidebar-foreground'
              }`}
            >
              <Icon className="h-4 w-4" />
              <span>{item.name}</span>
              {item.badge !== undefined && (
                <Badge variant="destructive" className="ml-auto h-5 px-1.5 text-[10px] min-w-[20px] flex items-center justify-center rounded-full">
                  {item.badge}
                </Badge>
              )}
            </div>
          </Link>
        );
      })}
    </div>
  );

  return (
    <div className="min-h-screen flex w-full bg-background">
      {/* Desktop Sidebar */}
      <aside className="hidden md:flex flex-col w-64 bg-sidebar border-r border-sidebar-border shrink-0 fixed inset-y-0 z-20">
        <div className="h-14 flex items-center px-4 border-b border-sidebar-border/50 shrink-0">
          <div className="flex items-center gap-2 font-bold text-sidebar-foreground truncate">
            <div className="w-6 h-6 rounded-sm bg-sidebar-primary flex items-center justify-center text-sidebar-primary-foreground text-xs">
              {agency?.name?.charAt(0) || 'A'}
            </div>
            <span className="truncate">{agency?.name || 'Agency Workspace'}</span>
          </div>
        </div>
        
        <div className="flex-1 overflow-y-auto p-3">
          <NavLinks />
        </div>
        
        <div className="p-4 border-t border-sidebar-border/50 shrink-0 mt-auto bg-sidebar/95">
          <div className="flex items-center gap-3 mb-4">
            <Avatar className="h-9 w-9 border border-sidebar-border/50">
              <AvatarFallback className="bg-sidebar-accent text-sidebar-foreground text-xs">
                {profile?.full_name?.substring(0, 2).toUpperCase() || 'U'}
              </AvatarFallback>
            </Avatar>
            <div className="flex flex-col flex-1 overflow-hidden">
              <span className="text-sm font-medium text-sidebar-foreground truncate">
                {profile?.full_name}
              </span>
              <span className="text-xs text-sidebar-foreground/60 capitalize truncate">
                {profile?.role}
              </span>
            </div>
          </div>
          <Button 
            variant="ghost" 
            className="w-full justify-start text-sidebar-foreground/80 hover:bg-sidebar-accent hover:text-sidebar-foreground" 
            onClick={signOut}
          >
            <LogOut className="mr-2 h-4 w-4" />
            Sign Out
          </Button>
        </div>
      </aside>

      {/* Main Content Area */}
      <div className="flex-1 flex flex-col md:pl-64 w-full overflow-hidden">
        {/* Mobile Header */}
        <header className="md:hidden h-14 border-b bg-card flex items-center justify-between px-4 shrink-0 sticky top-0 z-10">
          <div className="flex items-center gap-2 font-bold truncate">
            <div className="w-6 h-6 rounded-sm bg-primary flex items-center justify-center text-primary-foreground text-xs">
              {agency?.name?.charAt(0) || 'A'}
            </div>
            <span className="truncate text-sm">{agency?.name || 'Agency Workspace'}</span>
          </div>
          
          <Sheet open={isMobileMenuOpen} onOpenChange={setIsMobileMenuOpen}>
            <SheetTrigger asChild>
              <Button variant="ghost" size="icon" className="-mr-2">
                <Menu className="h-5 w-5" />
              </Button>
            </SheetTrigger>
            <SheetContent side="left" className="w-64 p-0 bg-sidebar border-r-sidebar-border">
              <div className="flex flex-col h-full">
                <div className="h-14 flex items-center px-4 border-b border-sidebar-border/50 shrink-0">
                  <span className="font-bold text-sidebar-foreground">Menu</span>
                </div>
                <div className="flex-1 overflow-y-auto p-3">
                  <NavLinks />
                </div>
                <div className="p-4 border-t border-sidebar-border/50 shrink-0 mt-auto bg-sidebar">
                  <div className="flex items-center gap-3 mb-4">
                    <Avatar className="h-9 w-9 border border-sidebar-border/50">
                      <AvatarFallback className="bg-sidebar-accent text-sidebar-foreground text-xs">
                        {profile?.full_name?.substring(0, 2).toUpperCase() || 'U'}
                      </AvatarFallback>
                    </Avatar>
                    <div className="flex flex-col flex-1 overflow-hidden">
                      <span className="text-sm font-medium text-sidebar-foreground truncate">
                        {profile?.full_name}
                      </span>
                      <span className="text-xs text-sidebar-foreground/60 capitalize truncate">
                        {profile?.role}
                      </span>
                    </div>
                  </div>
                  <Button 
                    variant="ghost" 
                    className="w-full justify-start text-sidebar-foreground/80 hover:bg-sidebar-accent hover:text-sidebar-foreground" 
                    onClick={signOut}
                  >
                    <LogOut className="mr-2 h-4 w-4" />
                    Sign Out
                  </Button>
                </div>
              </div>
            </SheetContent>
          </Sheet>
        </header>

        {/* Page Content */}
        <main className="flex-1 overflow-auto bg-background/50">
          <div className="container mx-auto p-4 md:p-6 max-w-7xl">
            {children}
          </div>
        </main>
      </div>
    </div>
  );
}
