import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { toast } from "sonner";
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip as RechartsTooltip,
  ResponsiveContainer,
} from "recharts";
import {
  Search,
  Mail,
  Settings,
  User,
  Home,
  FileText,
  Calendar,
  Menu,
  Camera,
  Star,
} from "lucide-react";

import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Toggle } from "@/components/ui/toggle";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Checkbox } from "@/components/ui/checkbox";
import { Switch } from "@/components/ui/switch";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Slider } from "@/components/ui/slider";
import { InputOTP, InputOTPGroup, InputOTPSlot } from "@/components/ui/input-otp";
import { Form, FormControl, FormDescription, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { Separator } from "@/components/ui/separator";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Breadcrumb, BreadcrumbItem, BreadcrumbLink, BreadcrumbList, BreadcrumbPage, BreadcrumbSeparator } from "@/components/ui/breadcrumb";
import { Pagination, PaginationContent, PaginationItem, PaginationLink, PaginationNext, PaginationPrevious } from "@/components/ui/pagination";
import { NavigationMenu, NavigationMenuContent, NavigationMenuItem, NavigationMenuLink, NavigationMenuList, NavigationMenuTrigger } from "@/components/ui/navigation-menu";
import { Menubar, MenubarContent, MenubarItem, MenubarMenu, MenubarSeparator, MenubarShortcut, MenubarTrigger } from "@/components/ui/menubar";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger } from "@/components/ui/alert-dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuSeparator, ContextMenuTrigger } from "@/components/ui/context-menu";
import { HoverCard, HoverCardContent, HoverCardTrigger } from "@/components/ui/hover-card";
import { Drawer, DrawerClose, DrawerContent, DrawerDescription, DrawerFooter, DrawerHeader, DrawerTitle, DrawerTrigger } from "@/components/ui/drawer";
import { AspectRatio } from "@/components/ui/aspect-ratio";
import { ScrollArea } from "@/components/ui/scroll-area";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/components/ui/resizable";

import { DataTable } from "@/components/data/DataTable";
import { StatusBadge, statusIconMap, type StatusConfig } from "@/components/StatusBadge";
import { PaginationBar } from "@/components/PaginationBar";
import { NavLink } from "@/components/NavLink";
import { type DateRange } from "react-day-picker";
import { DatePicker, DateRangePicker } from "@/components/date/DatePicker";
import { RichTextEditor } from "@/components/editor/RichTextEditor";
import { SortableList, type SortableItem } from "@/components/dnd/SortableList";
import { GanttChart, type GanttTask } from "@/components/gantt/GanttChart";
import { Dropzone } from "@/components/upload/Dropzone";
import { DocumentPreview } from "@/components/preview/DocumentPreview";

const formSchema = z.object({
  username: z.string().min(2, { message: "Username must be at least 2 characters." }),
  bio: z.string().max(160, { message: "Bio must not exceed 160 characters." }),
});

type FormValues = z.infer<typeof formSchema>;

const peopleData = [
  { id: "1", name: "Alice Müller", email: "alice@example.com", role: "Admin" },
  { id: "2", name: "Bob Schmidt", email: "bob@example.com", role: "Editor" },
  { id: "3", name: "Carol Weber", email: "carol@example.com", role: "Viewer" },
  { id: "4", name: "David Fischer", email: "david@example.com", role: "Editor" },
];

const chartData = [
  { month: "Jan", value: 120 },
  { month: "Feb", value: 200 },
  { month: "Mar", value: 150 },
  { month: "Apr", value: 280 },
  { month: "May", value: 220 },
  { month: "Jun", value: 310 },
];

const ganttTasks: GanttTask[] = [
  { id: 1, text: "Design", start: new Date(2026, 6, 1), duration: 5, progress: 100, type: "summary" },
  { id: 2, text: "Wireframes", start: new Date(2026, 6, 1), duration: 3, progress: 100, parent: 1 },
  { id: 3, text: "Mockups", start: new Date(2026, 6, 4), duration: 2, progress: 100, parent: 1 },
  { id: 4, text: "Build", start: new Date(2026, 6, 8), duration: 8, progress: 50, type: "summary" },
  { id: 5, text: "Frontend", start: new Date(2026, 6, 8), duration: 5, progress: 70, parent: 4 },
  { id: 6, text: "Backend", start: new Date(2026, 6, 10), duration: 6, progress: 30, parent: 4 },
  { id: 7, text: "Launch", start: new Date(2026, 6, 18), duration: 0, type: "milestone" },
];

const sortableItems: SortableItem[] = [
  { id: "a", label: "First item" },
  { id: "b", label: "Second item" },
  { id: "c", label: "Third item" },
];

const statusConfigs: StatusConfig[] = [
  { bgClass: "bg-green-100", textClass: "text-green-800", icon: statusIconMap.CheckCircle2, label: "Approved" },
  { bgClass: "bg-yellow-100", textClass: "text-yellow-800", icon: statusIconMap.AlertTriangle, label: "Pending" },
  { bgClass: "bg-red-100", textClass: "text-red-800", icon: statusIconMap.XCircle, label: "Rejected" },
];

function Section({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        {description && <CardDescription>{description}</CardDescription>}
      </CardHeader>
      <CardContent className="space-y-4">{children}</CardContent>
    </Card>
  );
}

function FormDemo() {
  const form = useForm<FormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: { username: "", bio: "" },
  });

  function onSubmit(values: FormValues) {
    toast.success(`Submitted! Username: ${values.username}`);
  }

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4 max-w-md">
        <FormField
          control={form.control}
          name="username"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Username</FormLabel>
              <FormControl>
                <Input placeholder="johndoe" {...field} />
              </FormControl>
              <FormDescription>Your public display name.</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="bio"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Bio</FormLabel>
              <FormControl>
                <Textarea placeholder="Tell us about yourself" {...field} />
              </FormControl>
              <FormDescription>Max 160 characters.</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <Button type="submit">Submit</Button>
      </form>
    </Form>
  );
}

export default function ShowcasePage() {
  const [sliderValue, setSliderValue] = useState([50]);
  const [switchChecked, setSwitchChecked] = useState(false);
  const [checkboxChecked, setCheckboxChecked] = useState(false);
  const [progressValue, setProgressValue] = useState(60);
  const [controlledSelect, setControlledSelect] = useState("");
  const [collapsibleOpen, setCollapsibleOpen] = useState(false);
  const [paginationPage, setPaginationPage] = useState(1);
  const [paginationPageSize, setPaginationPageSize] = useState(5);
  const [sortableItemsState, setSortableItemsState] = useState(sortableItems);
  const [showcaseDate, setShowcaseDate] = useState<Date>();
  const [showcaseDateRange, setShowcaseDateRange] = useState<DateRange>();

  return (
    <div className="min-h-screen bg-background">
      <div className="sticky top-0 z-30 bg-background/80 backdrop-blur border-b">
        <div className="max-w-7xl mx-auto px-4 py-3 flex items-center gap-3">
          <h1 className="text-xl font-bold">Component Showcase</h1>
          <Badge variant="secondary" className="text-xs">44+ components</Badge>
        </div>
      </div>

      <div className="max-w-7xl mx-auto px-4 py-8">
        <Tabs defaultValue="buttons" className="space-y-8">
          <TabsList className="flex-wrap h-auto gap-1">
            <TabsTrigger value="buttons">Buttons & Badges</TabsTrigger>
            <TabsTrigger value="forms">Forms & Inputs</TabsTrigger>
            <TabsTrigger value="data">Data Display</TabsTrigger>
            <TabsTrigger value="feedback">Feedback</TabsTrigger>
            <TabsTrigger value="navigation">Navigation</TabsTrigger>
            <TabsTrigger value="overlays">Overlays</TabsTrigger>
            <TabsTrigger value="components">Components</TabsTrigger>
          </TabsList>

          <TabsContent value="buttons" className="space-y-6">
            <Section title="Button Variants" description="6 variants: default, secondary, destructive, outline, ghost, link">
              <div className="flex flex-wrap gap-2">
                <Button>Default</Button>
                <Button variant="secondary">Secondary</Button>
                <Button variant="destructive">Destructive</Button>
                <Button variant="outline">Outline</Button>
                <Button variant="ghost">Ghost</Button>
                <Button variant="link">Link</Button>
              </div>
            </Section>

            <Section title="Button Sizes" description="4 sizes: sm, default, lg, icon">
              <div className="flex flex-wrap items-center gap-2">
                <Button size="sm">Small</Button>
                <Button>Default</Button>
                <Button size="lg">Large</Button>
                <Button size="icon"><Settings className="h-4 w-4" /></Button>
              </div>
            </Section>

            <Section title="Button with Icon & Loading">
              <div className="flex flex-wrap gap-2">
                <Button><Mail className="mr-2 h-4 w-4" /> Email</Button>
                <Button disabled><Search className="mr-2 h-4 w-4" /> Loading...</Button>
              </div>
            </Section>

            <Section title="Badge" description="4 variants: default, secondary, destructive, outline">
              <div className="flex flex-wrap gap-2">
                <Badge>Default</Badge>
                <Badge variant="secondary">Secondary</Badge>
                <Badge variant="destructive">Destructive</Badge>
                <Badge variant="outline">Outline</Badge>
              </div>
            </Section>

            <Section title="Toggle">
              <div className="flex flex-wrap gap-2">
                <Toggle aria-label="Toggle italic">B</Toggle>
                <Toggle aria-label="Toggle italic">I</Toggle>
                <Toggle aria-label="Toggle underline">U</Toggle>
              </div>
            </Section>

            <Section title="Toggle Group">
              <ToggleGroup type="single" defaultValue="left">
                <ToggleGroupItem value="left">Left</ToggleGroupItem>
                <ToggleGroupItem value="center">Center</ToggleGroupItem>
                <ToggleGroupItem value="right">Right</ToggleGroupItem>
              </ToggleGroup>
            </Section>

            <Section title="Tooltip">
              <div className="flex gap-2">
                <Tooltip>
                  <TooltipTrigger asChild>
                    <Button variant="outline">Hover me</Button>
                  </TooltipTrigger>
                  <TooltipContent>
                    <p>This is a tooltip</p>
                  </TooltipContent>
                </Tooltip>
              </div>
            </Section>
          </TabsContent>

          <TabsContent value="forms" className="space-y-6">
            <Section title="Input + Textarea + Label">
              <div className="space-y-4 max-w-md">
                <div className="space-y-2">
                  <Label htmlFor="demo-input">Email</Label>
                  <Input id="demo-input" placeholder="name@example.com" />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="demo-textarea">Message</Label>
                  <Textarea id="demo-textarea" placeholder="Type your message..." />
                </div>
              </div>
            </Section>

            <Section title="Select + Checkbox + Switch + Radio Group">
              <div className="space-y-4 max-w-md">
                <Select value={controlledSelect} onValueChange={setControlledSelect}>
                  <SelectTrigger className="w-[200px]">
                    <SelectValue placeholder="Choose a fruit" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="apple">Apple</SelectItem>
                    <SelectItem value="banana">Banana</SelectItem>
                    <SelectItem value="orange">Orange</SelectItem>
                  </SelectContent>
                </Select>
                <div className="flex items-center gap-2">
                  <Checkbox
                    id="demo-check"
                    checked={checkboxChecked}
                    onCheckedChange={(c) => setCheckboxChecked(!!c)}
                  />
                  <Label htmlFor="demo-check">Accept terms</Label>
                </div>
                <div className="flex items-center gap-2">
                  <Switch
                    checked={switchChecked}
                    onCheckedChange={setSwitchChecked}
                  />
                  <Label>{switchChecked ? "Enabled" : "Disabled"}</Label>
                </div>
                <RadioGroup defaultValue="comfortable">
                  <div className="flex items-center gap-2">
                    <RadioGroupItem value="default" id="r1" />
                    <Label htmlFor="r1">Default</Label>
                  </div>
                  <div className="flex items-center gap-2">
                    <RadioGroupItem value="comfortable" id="r2" />
                    <Label htmlFor="r2">Comfortable</Label>
                  </div>
                  <div className="flex items-center gap-2">
                    <RadioGroupItem value="compact" id="r3" />
                    <Label htmlFor="r3">Compact</Label>
                  </div>
                </RadioGroup>
              </div>
            </Section>

            <Section title="Slider" description={`Value: ${sliderValue[0]}`}>
              <div className="max-w-md">
                <Slider
                  value={sliderValue}
                  onValueChange={setSliderValue}
                  max={100}
                  step={1}
                />
              </div>
            </Section>

            <Section title="Input OTP" description="One-time password input (6 digits)">
              <InputOTP maxLength={6}>
                <InputOTPGroup>
                  <InputOTPSlot index={0} />
                  <InputOTPSlot index={1} />
                  <InputOTPSlot index={2} />
                  <InputOTPSlot index={3} />
                  <InputOTPSlot index={4} />
                  <InputOTPSlot index={5} />
                </InputOTPGroup>
              </InputOTP>
            </Section>

            <Section title="Form (react-hook-form + zod)" description="Zod-validated form with username (min 2) and bio (max 160)">
              <FormDemo />
            </Section>
          </TabsContent>

          <TabsContent value="data" className="space-y-6">
            <Section title="Card + Avatar + Separator">
              <div className="flex items-center gap-4">
                <Avatar>
                  <AvatarImage src="" />
                  <AvatarFallback>JD</AvatarFallback>
                </Avatar>
                <div>
                  <p className="font-medium">John Doe</p>
                  <p className="text-sm text-muted-foreground">john@example.com</p>
                </div>
                <Separator orientation="vertical" className="h-8" />
                <Badge variant="outline">Active</Badge>
              </div>
            </Section>

            <Section title="Accordion + Tabs + Collapsible">
              <Accordion type="single" collapsible className="w-full max-w-md">
                <AccordionItem value="item-1">
                  <AccordionTrigger>What is the fullstack template?</AccordionTrigger>
                  <AccordionContent>
                    A React + Vite + FastAPI template with shadcn/ui components.
                  </AccordionContent>
                </AccordionItem>
                <AccordionItem value="item-2">
                  <AccordionTrigger>Is it production-ready?</AccordionTrigger>
                  <AccordionContent>
                    Yes, it includes auth, testing, and Docker support.
                  </AccordionContent>
                </AccordionItem>
              </Accordion>

              <Tabs defaultValue="tab1" className="mt-4 max-w-md">
                <TabsList>
                  <TabsTrigger value="tab1">Account</TabsTrigger>
                  <TabsTrigger value="tab2">Password</TabsTrigger>
                </TabsList>
                <TabsContent value="tab1" className="border rounded-md p-4 mt-2">
                  <p className="text-sm text-muted-foreground">Account settings here.</p>
                </TabsContent>
                <TabsContent value="tab2" className="border rounded-md p-4 mt-2">
                  <p className="text-sm text-muted-foreground">Password settings here.</p>
                </TabsContent>
              </Tabs>

              <Collapsible
                open={collapsibleOpen}
                onOpenChange={setCollapsibleOpen}
                className="mt-4 max-w-md border rounded-md p-4"
              >
                <CollapsibleTrigger asChild>
                  <Button variant="ghost" size="sm">
                    {collapsibleOpen ? "Collapse" : "Expand"} details
                  </Button>
                </CollapsibleTrigger>
                <CollapsibleContent className="mt-2">
                  <p className="text-sm text-muted-foreground">
                    These are the collapsed details that become visible when you click the trigger.
                  </p>
                </CollapsibleContent>
              </Collapsible>
            </Section>

            <Section title="Table (Standalone)">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Name</TableHead>
                    <TableHead>Email</TableHead>
                    <TableHead>Role</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {peopleData.map((p) => (
                    <TableRow key={p.id}>
                      <TableCell>{p.name}</TableCell>
                      <TableCell>{p.email}</TableCell>
                      <TableCell>{p.role}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </Section>

            <Section title="DataTable (TanStack)" description="Sortable, paginated table with 4 rows">
              <DataTable
                columns={[
                  { accessorKey: "name", header: "Name" },
                  { accessorKey: "email", header: "Email" },
                  { accessorKey: "role", header: "Role" },
                ]}
                data={peopleData}
                pageSize={3}
              />
            </Section>

            <Section title="Command (cmdk Palette)">
              <Command className="rounded-lg border shadow-md max-w-md">
                <CommandInput placeholder="Search..." />
                <CommandList>
                  <CommandEmpty>No results found.</CommandEmpty>
                  <CommandGroup heading="Suggestions">
                    <CommandItem>
                      <Calendar className="mr-2 h-4 w-4" />
                      <span>Calendar</span>
                    </CommandItem>
                    <CommandItem>
                      <Search className="mr-2 h-4 w-4" />
                      <span>Search</span>
                    </CommandItem>
                    <CommandItem>
                      <Settings className="mr-2 h-4 w-4" />
                      <span>Settings</span>
                    </CommandItem>
                  </CommandGroup>
                </CommandList>
              </Command>
            </Section>

            <Section title="StatusBadge" description="3 demo configs using statusIconMap icons">
              <div className="flex gap-2">
                {statusConfigs.map((cfg, i) => (
                  <StatusBadge key={i} config={cfg} />
                ))}
              </div>
            </Section>

            <Section title="PaginationBar" description="With page size selector and state tracking">
              <PaginationBar
                page={paginationPage}
                totalPages={Math.ceil(peopleData.length / paginationPageSize)}
                pageSize={paginationPageSize}
                totalItems={peopleData.length}
                onPageChange={setPaginationPage}
                onPageSizeChange={(size) => {
                  setPaginationPageSize(size);
                  setPaginationPage(1);
                }}
              />
            </Section>
          </TabsContent>

          <TabsContent value="feedback" className="space-y-6">
            <Section title="Alert" description="3 variants: default, info, destructive">
              <div className="space-y-3 max-w-md">
                <Alert>
                  <AlertTitle>Default</AlertTitle>
                  <AlertDescription>
                    This is a default alert message.
                  </AlertDescription>
                </Alert>
                <Alert>
                  <AlertTitle>Info</AlertTitle>
                  <AlertDescription>
                    This is an informational alert.
                  </AlertDescription>
                </Alert>
                <Alert variant="destructive">
                  <AlertTitle>Error</AlertTitle>
                  <AlertDescription>
                    Something went wrong. Please try again.
                  </AlertDescription>
                </Alert>
              </div>
            </Section>

            <Section title="Progress" description={`Current: ${progressValue}%`}>
              <div className="space-y-2 max-w-md">
                <Progress value={progressValue} />
                <div className="flex gap-2">
                  <Button size="sm" variant="outline" onClick={() => setProgressValue((v) => Math.max(0, v - 10))}>-10%</Button>
                  <Button size="sm" variant="outline" onClick={() => setProgressValue((v) => Math.min(100, v + 10))}>+10%</Button>
                </div>
              </div>
            </Section>

            <Section title="Skeleton">
              <div className="space-y-3 max-w-md">
                <Skeleton className="h-4 w-[250px]" />
                <Skeleton className="h-4 w-[200px]" />
                <Skeleton className="h-4 w-[300px]" />
              </div>
            </Section>

            <Section title="Toast (sonner)">
              <div className="flex flex-wrap gap-2">
                <Button onClick={() => toast.success("Successfully saved!")}>
                  Success Toast
                </Button>
                <Button variant="destructive" onClick={() => toast.error("Something went wrong!")}>
                  Error Toast
                </Button>
                <Button variant="outline" onClick={() => toast("Hello world")}>
                  Default Toast
                </Button>
              </div>
            </Section>

            <Section title="Popover">
              <Popover>
                <PopoverTrigger asChild>
                  <Button variant="outline">Open popover</Button>
                </PopoverTrigger>
                <PopoverContent className="w-80">
                  <div className="space-y-2">
                    <h4 className="font-medium">Popover Content</h4>
                    <p className="text-sm text-muted-foreground">
                      This is a popover with some content.
                    </p>
                  </div>
                </PopoverContent>
              </Popover>
            </Section>
          </TabsContent>

          <TabsContent value="navigation" className="space-y-6">
            <Section title="Breadcrumb">
              <Breadcrumb>
                <BreadcrumbList>
                  <BreadcrumbItem>
                    <BreadcrumbLink href="/">Home</BreadcrumbLink>
                  </BreadcrumbItem>
                  <BreadcrumbSeparator />
                  <BreadcrumbItem>
                    <BreadcrumbLink href="/docs">Docs</BreadcrumbLink>
                  </BreadcrumbItem>
                  <BreadcrumbSeparator />
                  <BreadcrumbItem>
                    <BreadcrumbPage>Current</BreadcrumbPage>
                  </BreadcrumbItem>
                </BreadcrumbList>
              </Breadcrumb>
            </Section>

            <Section title="Pagination">
              <Pagination>
                <PaginationContent>
                  <PaginationItem>
                    <PaginationPrevious href="#" />
                  </PaginationItem>
                  <PaginationItem>
                    <PaginationLink href="#">1</PaginationLink>
                  </PaginationItem>
                  <PaginationItem>
                    <PaginationLink href="#" isActive>2</PaginationLink>
                  </PaginationItem>
                  <PaginationItem>
                    <PaginationLink href="#">3</PaginationLink>
                  </PaginationItem>
                  <PaginationItem>
                    <PaginationNext href="#" />
                  </PaginationItem>
                </PaginationContent>
              </Pagination>
            </Section>

            <Section title="Navigation Menu">
              <NavigationMenu>
                <NavigationMenuList>
                  <NavigationMenuItem>
                    <NavigationMenuTrigger>Getting Started</NavigationMenuTrigger>
                    <NavigationMenuContent>
                      <div className="p-4 w-[300px]">
                        <p className="text-sm font-medium">Introduction</p>
                        <p className="text-xs text-muted-foreground mt-1">
                          Learn the basics of the template.
                        </p>
                      </div>
                    </NavigationMenuContent>
                  </NavigationMenuItem>
                  <NavigationMenuItem>
                    <NavigationMenuLink href="#" className="px-2 py-1 text-sm">
                      Components
                    </NavigationMenuLink>
                  </NavigationMenuItem>
                </NavigationMenuList>
              </NavigationMenu>
            </Section>

            <Section title="Menubar">
              <Menubar>
                <MenubarMenu>
                  <MenubarTrigger>File</MenubarTrigger>
                  <MenubarContent>
                    <MenubarItem>New Tab <MenubarShortcut>⌘T</MenubarShortcut></MenubarItem>
                    <MenubarItem>New Window</MenubarItem>
                    <MenubarSeparator />
                    <MenubarItem>Save</MenubarItem>
                  </MenubarContent>
                </MenubarMenu>
                <MenubarMenu>
                  <MenubarTrigger>Edit</MenubarTrigger>
                  <MenubarContent>
                    <MenubarItem>Undo <MenubarShortcut>⌘Z</MenubarShortcut></MenubarItem>
                    <MenubarItem>Redo <MenubarShortcut>⇧⌘Z</MenubarShortcut></MenubarItem>
                  </MenubarContent>
                </MenubarMenu>
              </Menubar>
            </Section>

            <Section title="NavLink (Custom)">
              <div className="flex gap-4">
                <NavLink to="/" activeClassName="text-primary font-bold" className="text-sm text-muted-foreground hover:text-foreground transition-colors">
                  Dashboard
                </NavLink>
                <NavLink to="/showcase" activeClassName="text-primary font-bold" className="text-sm text-muted-foreground hover:text-foreground transition-colors">
                  Showcase
                </NavLink>
              </div>
            </Section>
          </TabsContent>

          <TabsContent value="overlays" className="space-y-6">
            <Section title="Dialog">
              <Dialog>
                <DialogTrigger asChild>
                  <Button variant="outline">Open Dialog</Button>
                </DialogTrigger>
                <DialogContent>
                  <DialogHeader>
                    <DialogTitle>Edit Profile</DialogTitle>
                    <DialogDescription>
                      Make changes to your profile here. Click save when done.
                    </DialogDescription>
                  </DialogHeader>
                  <div className="space-y-4">
                    <div className="space-y-2">
                      <Label htmlFor="dialog-name">Name</Label>
                      <Input id="dialog-name" defaultValue="John Doe" />
                    </div>
                  </div>
                  <DialogFooter>
                    <Button type="submit">Save changes</Button>
                  </DialogFooter>
                </DialogContent>
              </Dialog>
            </Section>

            <Section title="Sheet">
              <Sheet>
                <SheetTrigger asChild>
                  <Button variant="outline"><Menu className="mr-2 h-4 w-4" /> Open Sheet</Button>
                </SheetTrigger>
                <SheetContent>
                  <SheetHeader>
                    <SheetTitle>Navigation</SheetTitle>
                    <SheetDescription>
                      Browse the available sections below.
                    </SheetDescription>
                  </SheetHeader>
                  <div className="space-y-2 mt-4">
                    <Button variant="ghost" className="w-full justify-start"><Home className="mr-2 h-4 w-4" /> Home</Button>
                    <Button variant="ghost" className="w-full justify-start"><FileText className="mr-2 h-4 w-4" /> Documents</Button>
                    <Button variant="ghost" className="w-full justify-start"><Settings className="mr-2 h-4 w-4" /> Settings</Button>
                  </div>
                </SheetContent>
              </Sheet>
            </Section>

            <Section title="Alert Dialog">
              <AlertDialog>
                <AlertDialogTrigger asChild>
                  <Button variant="destructive">Delete Account</Button>
                </AlertDialogTrigger>
                <AlertDialogContent>
                  <AlertDialogHeader>
                    <AlertDialogTitle>Are you absolutely sure?</AlertDialogTitle>
                    <AlertDialogDescription>
                      This action cannot be undone. This will permanently delete your account.
                    </AlertDialogDescription>
                  </AlertDialogHeader>
                  <AlertDialogFooter>
                    <AlertDialogCancel>Cancel</AlertDialogCancel>
                    <AlertDialogAction>Continue</AlertDialogAction>
                  </AlertDialogFooter>
                </AlertDialogContent>
              </AlertDialog>
            </Section>

            <Section title="Dropdown Menu">
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="outline"><User className="mr-2 h-4 w-4" /> Account</Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent className="w-56">
                  <DropdownMenuLabel>My Account</DropdownMenuLabel>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem>Profile</DropdownMenuItem>
                  <DropdownMenuItem>Settings</DropdownMenuItem>
                  <DropdownMenuItem>Billing</DropdownMenuItem>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem>Logout</DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </Section>

            <Section title="Context Menu">
              <ContextMenu>
                <ContextMenuTrigger className="flex h-[150px] w-full items-center justify-center rounded-md border border-dashed text-sm">
                  Right click here
                </ContextMenuTrigger>
                <ContextMenuContent className="w-48">
                  <ContextMenuItem><Star className="mr-2 h-4 w-4" /> Favorite</ContextMenuItem>
                  <ContextMenuItem><Camera className="mr-2 h-4 w-4" /> Screenshot</ContextMenuItem>
                  <ContextMenuSeparator />
                  <ContextMenuItem><Settings className="mr-2 h-4 w-4" /> Settings</ContextMenuItem>
                </ContextMenuContent>
              </ContextMenu>
            </Section>

            <Section title="Hover Card">
              <HoverCard>
                <HoverCardTrigger asChild>
                  <Button variant="link">@johndoe</Button>
                </HoverCardTrigger>
                <HoverCardContent className="w-80">
                  <div className="flex gap-4">
                    <Avatar>
                      <AvatarFallback>JD</AvatarFallback>
                    </Avatar>
                    <div className="space-y-1">
                      <h4 className="text-sm font-semibold">@johndoe</h4>
                      <p className="text-sm text-muted-foreground">
                        Full-stack developer and open source contributor.
                      </p>
                    </div>
                  </div>
                </HoverCardContent>
              </HoverCard>
            </Section>

            <Section title="Drawer">
              <Drawer>
                <DrawerTrigger asChild>
                  <Button variant="outline">Open Drawer</Button>
                </DrawerTrigger>
                <DrawerContent>
                  <div className="mx-auto w-full max-w-sm">
                    <DrawerHeader>
                      <DrawerTitle>Move Goal</DrawerTitle>
                      <DrawerDescription>Set your daily activity goal.</DrawerDescription>
                    </DrawerHeader>
                    <div className="p-4 pb-0">
                      <div className="flex items-center justify-center space-x-2">
                        <Button variant="outline" className="h-8 w-8 shrink-0 rounded-full">-</Button>
                        <div className="flex-1 text-center">
                          <div className="text-7xl font-bold tracking-tighter">30</div>
                          <div className="text-[0.70rem] uppercase text-muted-foreground">min / day</div>
                        </div>
                        <Button variant="outline" className="h-8 w-8 shrink-0 rounded-full">+</Button>
                      </div>
                    </div>
                    <DrawerFooter>
                      <Button>Submit</Button>
                      <DrawerClose asChild>
                        <Button variant="outline">Cancel</Button>
                      </DrawerClose>
                    </DrawerFooter>
                  </div>
                </DrawerContent>
              </Drawer>
            </Section>
          </TabsContent>

          <TabsContent value="components" className="space-y-6">
            <Section title="DatePicker + DateRangePicker" description="Date range picker has built-in preset sidebar">
              <div className="flex flex-wrap gap-4">
                <DatePicker value={showcaseDate} onChange={setShowcaseDate} />
                <DateRangePicker value={showcaseDateRange} onChange={setShowcaseDateRange} />
              </div>
            </Section>

            <Section title="Resizable Panel Group">
              <ResizablePanelGroup direction="horizontal" className="max-w-md rounded-lg border min-h-[200px]">
                <ResizablePanel defaultSize={50}>
                  <div className="flex h-full items-center justify-center p-6">
                    <span className="text-sm text-muted-foreground">Panel A</span>
                  </div>
                </ResizablePanel>
                <ResizableHandle withHandle />
                <ResizablePanel defaultSize={50}>
                  <div className="flex h-full items-center justify-center p-6">
                    <span className="text-sm text-muted-foreground">Panel B</span>
                  </div>
                </ResizablePanel>
              </ResizablePanelGroup>
            </Section>

            <Section title="Scroll Area">
              <ScrollArea className="h-[200px] w-full max-w-md rounded-md border p-4">
                <div className="space-y-2">
                  {Array.from({ length: 20 }).map((_, i) => (
                    <div key={i} className="p-2 rounded bg-muted text-sm">
                      Scroll item {i + 1}
                    </div>
                  ))}
                </div>
              </ScrollArea>
            </Section>

            <Section title="Aspect Ratio" description="16:9 container with a centered placeholder">
              <AspectRatio ratio={16 / 9} className="bg-muted max-w-md">
                <div className="flex h-full items-center justify-center">
                  <span className="text-sm text-muted-foreground">16:9</span>
                </div>
              </AspectRatio>
            </Section>

            <Section title="Rich Text Editor (Tiptap)">
              <RichTextEditor placeholder="Start writing..." />
            </Section>

            <Section title="Sortable List (dnd-kit)">
              <SortableList items={sortableItemsState} onChange={setSortableItemsState} className="max-w-md" />
            </Section>

            <Section title="Gantt Chart" description="3 tasks: Design → Build → Launch, pure SVG">
              <GanttChart tasks={ganttTasks} />
            </Section>

            <Section title="Dropzone" description="Drag & drop file upload">
              <Dropzone className="max-w-md" />
            </Section>

            <Section title="Document Preview" description="PDF placeholder — no document loaded">
              <div className="max-w-md">
                <DocumentPreview file={null} />
              </div>
            </Section>

            <Section title="Line Chart (Recharts)" description="6-month sample data">
              <div className="max-w-md">
                <ResponsiveContainer width="100%" height={250}>
                  <LineChart data={chartData}>
                    <CartesianGrid strokeDasharray="3 3" />
                    <XAxis dataKey="month" />
                    <YAxis />
                    <RechartsTooltip />
                    <Line type="monotone" dataKey="value" stroke="var(--primary)" strokeWidth={2} />
                  </LineChart>
                </ResponsiveContainer>
              </div>
            </Section>
          </TabsContent>
        </Tabs>
      </div>
    </div>
  );
}
