--  SPDX-License-Identifier: GPL-3.0-or-later
package body Paging_Gate with
  SPARK_Mode,
  Refined_State => (State => (Pool, Built))
is
   Page_4K : constant U64 := 2**12;
   Page_2M : constant U64 := 2**21;

   Max_Lower_Half : constant U64 := 2**38;
   Max_Physical   : constant U64 := 2**55;

   Pool : Table_Pool := (others => (others => 0)) with
     Export,
     Convention    => C,
     External_Name => "fb_page_pool",
     Alignment     => 4096;

   Built : Boolean := False;

   function To_Status (Result : Status) return U64 is
     (case Result is
        when Ok       => Status_Ok,
        when No_Space => Status_No_Space,
        when Conflict => Status_Conflict);

   procedure Map_Region
     (Tree   : in out Table_Pool;
      Used   : in out Table_Total;
      Base   : U64;
      Item   : Region;
      Code   : out U64)
   with
     Pre  =>
       Base <= Max_Base_Ppn
       and then Used >= 1
       and then Well_Formed (Tree, Base, Used),
     Post =>
       Used >= 1
       and then Well_Formed (Tree, Base, Used)
   is
      Step   : U64;
      Size   : Page_Size;
      Perm   : Permission;
      Done   : U64 := 0;
      Result : Status;
   begin
      Code := Status_Invalid;

      case Item.Size is
         when 0 =>
            Size := Size_4K;
            Step := Page_4K;
         when 1 =>
            Size := Size_2M;
            Step := Page_2M;
         when others =>
            return;
      end case;

      case Item.Perm is
         when 1 =>
            Perm := Read_Only;
         when 2 =>
            Perm := Read_Write;
         when 3 =>
            Perm := Read_Execute;
         when others =>
            return;
      end case;

      if Item.Length = 0
        or else Item.Va mod Step /= 0
        or else Item.Pa mod Step /= 0
        or else Item.Length mod Step /= 0
        or else Item.Va >= Max_Lower_Half
        or else Item.Length > Max_Lower_Half - Item.Va
        or else Item.Pa >= Max_Physical
      then
         return;
      end if;

      while Done < Item.Length loop
         pragma Loop_Invariant (Used >= 1);
         pragma Loop_Invariant (Well_Formed (Tree, Base, Used));
         pragma Loop_Invariant (Done < Item.Length);
         pragma Loop_Variant (Decreases => Item.Length - Done);

         Map_Page
           (Pool   => Tree,
            Used   => Used,
            Base   => Base,
            Va     => Item.Va + Done,
            Ppn    => (Item.Pa + Done) / Page_4K,
            Perm   => Perm,
            Size   => Size,
            Result => Result);

         if Result /= Ok then
            Code := To_Status (Result);
            return;
         end if;

         exit when Item.Length - Done <= Step;
         Done := Done + Step;
      end loop;

      Code := Status_Ok;
   end Map_Region;

   function Build
     (Regions   : Region_Table;
      Count     : U64;
      Pool_Base : U64) return U64
   is
      Used : Table_Total := 1;
      Code : U64;
      Base : U64;
   begin
      if Built then
         return Status_Already_Built;
      elsif Count > U64 (Max_Regions)
        or else Pool_Base mod Page_4K /= 0
        or else Pool_Base >= Max_Physical
      then
         return Status_Invalid;
      end if;

      Base := Pool_Base / Page_4K;
      Pool := (others => (others => 0));

      for Index in U64 range 1 .. Count loop
         pragma Loop_Invariant (Used >= 1);
         pragma Loop_Invariant (Well_Formed (Pool, Base, Used));

         Map_Region (Pool, Used, Base, Regions (Region_Index (Index - 1)), Code);
         if Code /= Status_Ok then
            return Code;
         end if;
      end loop;

      Built := True;
      return Status_Ok;
   end Build;

end Paging_Gate;
