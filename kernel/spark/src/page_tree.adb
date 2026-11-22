--  SPDX-License-Identifier: GPL-3.0-or-later
package body Page_Tree with
  SPARK_Mode
is

   function Vpn (Va : U64; L : Level) return Entry_Index is
      Shifted : constant U64 :=
        (case L is
           when 0 => Va / 2**12,
           when 1 => Va / 2**21,
           when 2 => Va / 2**30);
   begin
      return Entry_Index (Shifted and 511);
   end Vpn;

   --  Baja un nivel: sigue el puntero existente o reserva una tabla nueva.
   procedure Descend
     (Pool   : in out Table_Pool;
      Used   : in out Table_Total;
      Base   : U64;
      Parent : Table_Id;
      Index  : Entry_Index;
      Child  : out Table_Id;
      Result : out Status)
   with
     Pre  =>
       Base <= Max_Base_Ppn
       and then Used >= 1
       and then Parent < Used
       and then Well_Formed (Pool, Base, Used),
     Post =>
       Used >= Used'Old
       and then Well_Formed (Pool, Base, Used)
       and then Only_Fills (Pool'Old, Pool)
       and then
         (if Result = Ok
          then Child < Used
            and then Child > Parent
            and then Points_Inside (Pool (Parent) (Index), Base)
            and then Child_Of (Pool (Parent) (Index), Base) = Child)
   is
      Current : constant U64 := Pool (Parent) (Index);
   begin
      Child  := Parent;
      Result := Ok;

      if Current = 0 then
         if Used = Max_Tables then
            Result := No_Space;
            return;
         end if;

         Child := Used;
         Pool (Parent) (Index) := Table_Entry (Base + U64 (Child));
         Used := Used + 1;

      elsif Is_Leaf (Current) then
         Result := Conflict;

      else
         pragma Assert (Is_Table (Current));
         Child := Table_Id (Ppn_Of (Current) - Base);
      end if;
   end Descend;

   --  Escribe la hoja solo si la entrada está libre.
   procedure Install
     (Pool   : in out Table_Pool;
      Used   : Table_Total;
      Base   : U64;
      Table  : Table_Id;
      Index  : Entry_Index;
      Ppn    : U64;
      Perm   : Permission;
      Result : out Status)
   with
     Pre  =>
       Base <= Max_Base_Ppn
       and then Table < Used
       and then Ppn < Max_Ppn
       and then Well_Formed (Pool, Base, Used),
     Post =>
       Well_Formed (Pool, Base, Used)
       and then Only_Fills (Pool'Old, Pool)
       and then
         (for all T in Table_Id =>
            (for all I in Entry_Index =>
               (if T /= Table or I /= Index
                then Pool (T) (I) = Pool'Old (T) (I))))
       and then
         (if Result = Ok then Pool (Table) (Index) = Leaf_Entry (Ppn, Perm))
   is
   begin
      if Pool (Table) (Index) /= 0 then
         Result := Conflict;
         return;
      end if;

      Pool (Table) (Index) := Leaf_Entry (Ppn, Perm);
      Result := Ok;
   end Install;

   procedure Map_Page
     (Pool   : in out Table_Pool;
      Used   : in out Table_Total;
      Base   : U64;
      Va     : U64;
      Ppn    : U64;
      Perm   : Permission;
      Size   : Page_Size;
      Result : out Status)
   is
      Middle : Table_Id;
      Bottom : Table_Id;
   begin
      Descend (Pool, Used, Base, 0, Vpn (Va, 2), Middle, Result);
      if Result /= Ok then
         return;
      end if;

      if Size = Size_2M then
         Install (Pool, Used, Base, Middle, Vpn (Va, 1), Ppn, Perm, Result);
         return;
      end if;

      Descend (Pool, Used, Base, Middle, Vpn (Va, 1), Bottom, Result);
      if Result /= Ok then
         return;
      end if;

      Install (Pool, Used, Base, Bottom, Vpn (Va, 0), Ppn, Perm, Result);
   end Map_Page;

end Page_Tree;
