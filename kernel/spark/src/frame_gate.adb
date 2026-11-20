with Frame_Bitmap; use Frame_Bitmap;

package body Frame_Gate with
  SPARK_Mode,
  Refined_State => (State => (Map, Usable, Base_Address, Next_Hint))
is
   Page_Size : constant U64 := 4096;

   --  Todo a cero: antes de Init no hay ningún marco que asignar.
   Map          : Free_Map    := (others => 0);
   Usable       : Frame_Total := 0;
   Base_Address : U64         := 0;
   Next_Hint    : Frame_Index := 0;

   function Init (Base : U64; Count : U64) return U64 is
   begin
      if Usable /= 0 then
         return Status_Already_Init;
      elsif Count = 0 or else Count > U64 (Max_Frames) then
         return Status_Out_Of_Range;
      elsif Base mod Page_Size /= 0 then
         return Status_Misaligned;
      elsif Base = 0 or else Base > U64'Last - Count * Page_Size then
         return Status_Out_Of_Range;
      end if;

      Mark_Usable (Map, Frame_Total (Count));
      Usable       := Frame_Total (Count);
      Base_Address := Base;
      Next_Hint    := 0;
      return Status_Ok;
   end Init;

   function Alloc return U64 is
      Found : Boolean;
      Frame : Frame_Index;
      Limit : Frame_Index;
   begin
      if Usable = 0 then
         return 0;
      end if;

      Limit := Usable - 1;
      Allocate
        (Map, Limit, (if Next_Hint <= Limit then Next_Hint else 0), Found, Frame);

      if not Found then
         return 0;
      end if;

      Next_Hint := (if Frame < Limit then Frame + 1 else 0);
      return Base_Address + U64 (Frame) * Page_Size;
   end Alloc;

   function Free (Address : U64) return U64 is
      Offset : U64;
      Index  : U64;
      Frame  : Frame_Index;
   begin
      if Usable = 0 or else Address < Base_Address then
         return Status_Out_Of_Range;
      end if;

      Offset := Address - Base_Address;
      if Offset mod Page_Size /= 0 then
         return Status_Misaligned;
      end if;

      Index := Offset / Page_Size;
      if Index >= U64 (Usable) then
         return Status_Out_Of_Range;
      end if;

      Frame := Frame_Index (Index);
      if Is_Free (Map, Frame) then
         return Status_Not_Assigned;
      end if;

      Release (Map, Frame);
      return Status_Ok;
   end Free;

end Frame_Gate;
