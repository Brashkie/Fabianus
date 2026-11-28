--  SPDX-License-Identifier: GPL-3.0-or-later
package body Fs_Core with
  SPARK_Mode
is
   No_Owner : constant Owner_Record := (Used => 0, File => 0, Slot => 0, Pad => 0);

   Empty_Entry : constant Entry_Record :=
     (Used   => 0,
      Kind   => 0,
      Parent => 0,
      Pad    => 0,
      Length => 0,
      Gen    => 0,
      Name   => (others => 0),
      Blocks => (others => 0));

   --  Ninguna operación que no cambia la tabla rompe Step_Ok.
   procedure Lemma_Step_Same (T : Table) with
     Ghost,
     Global => null,
     Post   => Step_Ok (T, T)
   is
   begin
      null;
   end Lemma_Step_Same;

   procedure Lemma_Same_Object (H : History; File, Gen : U64) is
      F : constant File_Index := File_Index (File);
      G : constant U32 := H (H'First) (F).Gen;
   begin
      pragma Assert (U64 (G) = Gen);
      pragma Assert (U64 (H (H'Last) (F).Gen) = Gen);
      --  Hacia delante, ninguna generación baja de G.
      for K in H'First .. H'Last loop
         if K > H'First then
            pragma Assert (Step_Ok (H (K - 1), H (K)));
            pragma Assert (H (K) (F).Gen >= H (K - 1) (F).Gen);
         end if;
         pragma Loop_Invariant
           (for all J in H'First .. K => H (J) (F).Gen >= G);
      end loop;
      --  Hacia atrás, ninguna pasa de la del final, que es G.
      for K in reverse H'First .. H'Last loop
         if K < H'Last then
            pragma Assert (Step_Ok (H (K), H (K + 1)));
            pragma Assert (H (K + 1) (F).Gen >= H (K) (F).Gen);
         end if;
         pragma Loop_Invariant
           (for all J in K .. H'Last => H (J) (F).Gen <= G);
      end loop;
      --  Todas son G, así que la entrada nunca dejó de estar en uso ni
      --  cambió de tipo.
      for K in H'First .. H'Last loop
         if K > H'First then
            pragma Assert (Step_Ok (H (K - 1), H (K)));
            pragma Assert (H (K - 1) (F).Gen = G and then H (K) (F).Gen = G);
            pragma Assert (Is_Used (H (K - 1) (F)));
            pragma Assert (Is_Used (H (K) (F)));
         end if;
         pragma Loop_Invariant
           (for all J in H'First .. K =>
              Is_Used (H (J) (F))
              and then H (J) (F).Gen = G
              and then H (J) (F).Kind = H (H'First) (F).Kind);
      end loop;
   end Lemma_Same_Object;

   --  Lo que significa Count_Of, sin divisiones.
   procedure Lemma_Count (L : U32) with
     Ghost,
     Global => null,
     Pre    => L <= Max_Length,
     Post   =>
       (if L = 0 then Count_Of (L) = 0
        else Count_Of (L) >= 1
          and then U64 (Count_Of (L) - 1) * Block_Bytes < U64 (L)
          and then U64 (L) <= U64 (Count_Of (L)) * Block_Bytes)
   is
   begin
      null;
   end Lemma_Count;

   procedure Lemma_Disjoint
     (T : Table; O : Owner_Map; D : Depth_Map; F, G : File_Index;
      S, R : Slot_Index)
   is
   begin
      pragma Assert (Owner_Is (O, Block_Index (T (F).Blocks (S)), F, S));
      pragma Assert (Owner_Is (O, Block_Index (T (G).Blocks (R)), G, R));
   end Lemma_Disjoint;

   procedure Lemma_Free_Unnamed
     (T : Table; O : Owner_Map; D : Depth_Map; B : Block_Index)
   is
   begin
      null;
   end Lemma_Free_Unnamed;

   --  Un paso hacia arriba: el directorio de una entrada está en uso y
   --  tiene un nivel menos.
   procedure Lemma_Step (T : Table; O : Owner_Map; D : Depth_Map; F : File_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Parents_Ok (T) and then Depths_Ok (T, D)
       and then Is_Used (T (F)) and then not At_Root (T (F)),
     Post   =>
       T (F).Parent < Max_Files
       and then Is_Used (T (File_Index (T (F).Parent)))
       and then D (File_Index (T (F).Parent)) >= 1
       and then Integer (D (F)) = Integer (D (File_Index (T (F).Parent))) + 1
   is
      pragma Unreferenced (O);
   begin
      pragma Assert (Depths_Ok (T, D));
      pragma Assert (Parents_Ok (T));
      pragma Assert (for all G in File_Index => Depth_Ok (T, D, G));
      pragma Assert (Depth_Ok (T, D, F));
      pragma Assert (T (F).Parent < Max_Files);
      pragma Assert (Is_Used (T (File_Index (T (F).Parent))));
      pragma Assert (D (File_Index (T (F).Parent)) >= 1);
   end Lemma_Step;

   procedure Lemma_No_Cycle
     (T : Table; O : Owner_Map; D : Depth_Map; C : Chain; K : Chain_Length)
   is
   begin
      pragma Assert (Depths_Ok (T, D));
      pragma Assert (Parents_Ok (T));
      pragma Assert (Is_Used (T (C (0))));
      pragma Assert (Depth_Ok (T, D, C (0)));
      for I in 1 .. K loop
         --  C (I) es el directorio de C (I - 1): está en uso y tiene un
         --  nivel menos.
         pragma Assert (Is_Used (T (C (I - 1))));
         pragma Assert (U64 (T (C (I - 1)).Parent) = U64 (C (I)));
         pragma Assert (not At_Root (T (C (I - 1))));
         pragma Assert (T (C (I - 1)).Parent = U8 (C (I)));
         Lemma_Step (T, O, D, C (I - 1));
         pragma Assert (File_Index (T (C (I - 1)).Parent) = C (I));
         pragma Assert (Is_Used (T (C (I))));
         pragma Assert (Integer (D (C (I - 1))) = Integer (D (C (I))) + 1);
         pragma Loop_Invariant (Is_Used (T (C (I))));
         pragma Loop_Invariant (D (C (I)) >= 1);
         pragma Loop_Invariant
           (Integer (D (C (I))) + I = Integer (D (C (0))));
      end loop;
   end Lemma_No_Cycle;

   --  Si solo cambian la entrada F y su profundidad, y ninguna otra entrada
   --  en uso tiene a F por directorio, las profundidades de las demás siguen
   --  valiendo.
   procedure Lemma_Depths_One
     (T_Old, T : Table; D_Old, D : Depth_Map; F : File_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Depths_Ok (T_Old, D_Old)
       and then Depth_Ok (T, D, F)
       and then
         (for all G in File_Index =>
            (if G /= F
             then T (G).Used = T_Old (G).Used
               and then T (G).Parent = T_Old (G).Parent
               and then D (G) = D_Old (G)
               and then
                 (if Is_Used (T (G)) and then not At_Root (T (G))
                  then T (G).Parent /= U8 (F)))),
     Post   => Depths_Ok (T, D)
   is
   begin
      for G in File_Index loop
         if G /= F then
            pragma Assert (Depth_Ok (T_Old, D_Old, G));
            pragma Assert (Depth_Ok (T, D, G));
         end if;
         pragma Loop_Invariant
           (for all H in File_Index'First .. G => Depth_Ok (T, D, H));
      end loop;
   end Lemma_Depths_One;

   --  Si ninguna entrada cambia de uso ni de directorio, las profundidades
   --  siguen valiendo.
   procedure Lemma_Depths_Frame (T_Old, T : Table; D : Depth_Map) with
     Ghost,
     Global => null,
     Pre    =>
       Depths_Ok (T_Old, D)
       and then
         (for all G in File_Index =>
            T (G).Used = T_Old (G).Used and then T (G).Parent = T_Old (G).Parent),
     Post   => Depths_Ok (T, D)
   is
   begin
      for G in File_Index loop
         pragma Assert (Depth_Ok (T_Old, D, G));
         pragma Assert (Depth_Ok (T, D, G));
         pragma Loop_Invariant
           (for all H in File_Index'First .. G => Depth_Ok (T, D, H));
      end loop;
   end Lemma_Depths_Frame;

   ----------------
   -- Profundidad --
   ----------------

   --  Lo que ya se sabe de las profundidades a medio calcular: 0 si aún no
   --  se conoce; si no, la de su directorio (ya conocida) más uno.
   function Partial_At (T : Table; D : Depth_Map; F : File_Index) return Boolean is
     (if D (F) /= 0
      then Is_Used (T (F))
        and then D (F) <= Max_Depth
        and then
          (if At_Root (T (F)) then D (F) = 1
           else T (F).Parent < Max_Files
             and then D (File_Index (T (F).Parent)) /= 0
             and then
               Integer (D (F)) = Integer (D (File_Index (T (F).Parent))) + 1))
   with Ghost;

   function Partial (T : Table; D : Depth_Map) return Boolean is
     (for all F in File_Index => Partial_At (T, D, F))
   with Ghost;

   --  Dar su profundidad a una entrada que no la tenía no estropea las demás:
   --  ninguna con profundidad tenía a esa por directorio.
   procedure Lemma_Partial_Set (T : Table; D_Prev, D : Depth_Map; F : File_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Partial (T, D_Prev)
       and then Partial_At (T, D, F)
       and then (D_Prev (F) = 0 or else D (F) = D_Prev (F))
       and then (for all G in File_Index => (if G /= F then D (G) = D_Prev (G))),
     Post   => Partial (T, D)
   is
   begin
      for G in File_Index loop
         if G /= F then
            pragma Assert (Partial_At (T, D_Prev, G));
            pragma Assert (Partial_At (T, D, G));
         end if;
         pragma Loop_Invariant
           (for all H in File_Index'First .. G => Partial_At (T, D, H));
      end loop;
   end Lemma_Partial_Set;

   --  Calcula la profundidad de cada entrada desde cero, por rondas: en cada
   --  una, una entrada recibe la suya si la de su directorio ya se conoce.
   --  Falla (Ok = False) si alguna entrada no la recibe: un ciclo, o algo
   --  más hondo que Max_Depth.
   procedure Rank_All (T : Table; D : out Depth_Map; Ok : out Boolean) with
     Global => null,
     Post   => (if Ok then Depths_Ok (T, D))
   is
      Changed : Boolean;
      D_Prev : Depth_Map with Ghost;
   begin
      D := (others => 0);
      Ok := False;
      for Round in 1 .. Max_Depth loop
         Changed := False;
         for F in File_Index loop
            if D (F) = 0 and then Is_Used (T (F)) then
               if At_Root (T (F)) then
                  D_Prev := D;
                  D (F) := 1;
                  Lemma_Partial_Set (T, D_Prev, D, F);
                  Changed := True;
               elsif T (F).Parent < Max_Files then
                  declare
                     P : constant File_Index := File_Index (T (F).Parent);
                  begin
                     if D (P) /= 0 and then D (P) < Max_Depth then
                        pragma Assert (P /= F);
                        D_Prev := D;
                        D (F) := D (P) + 1;
                        pragma Assert (Integer (D (F)) = Integer (D (P)) + 1);
                        pragma Assert (Partial_At (T, D, F));
                        Lemma_Partial_Set (T, D_Prev, D, F);
                        Changed := True;
                     end if;
                  end;
               end if;
            end if;
            pragma Loop_Invariant (Partial (T, D));
         end loop;
         pragma Loop_Invariant (Partial (T, D));
         exit when not Changed;
      end loop;

      for F in File_Index loop
         if Is_Used (T (F)) and then D (F) = 0 then
            return;
         end if;
         pragma Loop_Invariant
           (for all G in File_Index'First .. F =>
              (if Is_Used (T (G)) then D (G) /= 0));
      end loop;
      pragma Assert (for all F in File_Index => Depth_Ok (T, D, F));
      Ok := True;
   end Rank_All;

   -----------
   -- Mount --
   -----------

   procedure Mount
     (Super : Super_Record; T : Table; O : out Owner_Map; D : out Depth_Map;
      Status : out U64)
   is
      Ranked : Boolean;
   begin
      O := (others => No_Owner);
      D := (others => 0);
      Status := Status_Unformatted;
      if Super.Magic /= Magic
        or else Super.Version /= Version
        or else Super.Blocks /= Max_Blocks
        or else Super.Files /= Max_Files
      then
         return;
      end if;
      Status := Status_Corrupt;

      for F in File_Index loop
         if not Entry_Ok (T (F)) then
            return;
         end if;
         pragma Loop_Invariant (for all G in File_Index'First .. F => Entry_Ok (T (G)));
      end loop;
      pragma Assert (Entries_Ok (T));

      --  El mapa, bloque a bloque: un bloque que ya tenía dueño es un error.
      for F in File_Index loop
         if Is_Used (T (F)) then
            for S in Slot_Index loop
               exit when Integer (S) >= Count (T (F));
               declare
                  B : constant Block_Index := Block_Index (T (F).Blocks (S));
               begin
                  if Owned (O, B) then
                     return;
                  end if;
                  O (B) :=
                    (Used => 1, File => U8 (F), Slot => U8 (S), Pad => 0);
               end;
               pragma Loop_Invariant (Map_To_Table (T, O));
               pragma Loop_Invariant
                 (for all G in File_Index =>
                    (for all R in Slot_Index =>
                       (if (G < F or else (G = F and then R <= S))
                          and then In_File (T (G), R)
                        then Owner_Is (O, Block_Index (T (G).Blocks (R)), G, R))));
            end loop;
         end if;
         pragma Loop_Invariant (Map_To_Table (T, O));
         pragma Loop_Invariant
           (for all G in File_Index =>
              (for all R in Slot_Index =>
                 (if G <= F and then In_File (T (G), R)
                  then Owner_Is (O, Block_Index (T (G).Blocks (R)), G, R))));
      end loop;
      pragma Assert (Table_To_Map (T, O));

      --  Dos nombres iguales en un mismo directorio son un error.
      for F in File_Index loop
         for G in File_Index loop
            if F /= G
              and then Is_Used (T (F))
              and then Is_Used (T (G))
              and then T (F).Parent = T (G).Parent
              and then T (F).Name = T (G).Name
            then
               return;
            end if;
            pragma Loop_Invariant
              (for all H in File_Index'First .. G =>
                 (if F /= H and then Is_Used (T (F)) and then Is_Used (T (H))
                    and then T (F).Parent = T (H).Parent
                  then T (F).Name /= T (H).Name));
         end loop;
         pragma Loop_Invariant
           (for all E in File_Index'First .. F =>
              (for all H in File_Index =>
                 (if E /= H and then Is_Used (T (E)) and then Is_Used (T (H))
                    and then T (E).Parent = T (H).Parent
                  then T (E).Name /= T (H).Name)));
      end loop;
      pragma Assert (Names_Unique (T));

      --  El directorio de cada entrada debe ser un directorio en uso.
      for F in File_Index loop
         if Is_Used (T (F)) and then not At_Root (T (F)) then
            pragma Assert (Entry_Ok (T (F)));
            declare
               P : constant File_Index := File_Index (T (F).Parent);
            begin
               if not Is_Used (T (P)) or else not Is_Dir (T (P)) then
                  return;
               end if;
            end;
         end if;
         pragma Loop_Invariant
           (for all G in File_Index'First .. F =>
              (if Is_Used (T (G)) and then not At_Root (T (G))
               then T (G).Parent < Max_Files
                 and then Is_Used (T (File_Index (T (G).Parent)))
                 and then Is_Dir (T (File_Index (T (G).Parent)))));
      end loop;
      pragma Assert (Parents_Ok (T));

      --  Las profundidades: sin ciclos, todas se pueden calcular.
      Rank_All (T, D, Ranked);
      if not Ranked then
         return;
      end if;

      Status := Status_Ok;
   end Mount;

   ------------
   -- Format --
   ------------

   procedure Format
     (Super : out Super_Record; T : in out Table; O : out Owner_Map;
      D : out Depth_Map; Keep : U64)
   is
      T_Old : constant Table := T with Ghost;
      Gen : U32;
   begin
      Super :=
        (Magic   => Magic,
         Version => Version,
         Blocks  => Max_Blocks,
         Files   => Max_Files,
         Unused  => 0);
      for F in File_Index loop
         Gen := 0;
         if Keep /= 0 then
            Gen := T (F).Gen;
            if Gen < Gen_Last then
               Gen := Gen + 1;
            end if;
         end if;
         T (F) := Empty_Entry;
         T (F).Gen := Gen;
         pragma Loop_Invariant
           (for all G in File_Index'First .. F =>
              T (G).Used = 0
              and then T (G).Length = 0
              and then T (G).Blocks = Empty_Entry.Blocks
              and then
                (if Keep /= 0
                 then
                   (if T_Old (G).Gen < Gen_Last
                    then T (G).Gen = T_Old (G).Gen + 1
                    else T (G).Gen = Gen_Last)
                 else T (G).Gen = 0));
         pragma Loop_Invariant
           (for all G in File_Index =>
              (if G > F then T (G) = T_Old (G)));
      end loop;
      O := (others => No_Owner);
      D := (others => 0);
      pragma Assert (Entries_Ok (T));
      pragma Assert (Depths_Ok (T, D));
      pragma Assert
        (if Keep /= 0 and then Entries_Ok (T_Old) then Step_Ok (T_Old, T));
   end Format;

   ------------
   -- Lookup --
   ------------

   procedure Lookup
     (T : Table; O : Owner_Map; D : Depth_Map; Dir : U64; Name : Name_Array;
      File : out U64; Status : out U64)
   is
      pragma Unreferenced (O, D);
   begin
      File := Max_Files;
      if Dir /= Root_Dir then
         if Dir >= Max_Files then
            Status := Status_Request;
            return;
         end if;
         if not Is_Used (T (File_Index (Dir))) then
            Status := Status_Not_Found;
            return;
         end if;
         if not Is_Dir (T (File_Index (Dir))) then
            Status := Status_Not_Dir;
            return;
         end if;
      end if;

      for F in File_Index loop
         if Is_Used (T (F))
           and then U64 (T (F).Parent) = Dir
           and then T (F).Name = Name
         then
            File := U64 (F);
            Status := Status_Ok;
            return;
         end if;
         pragma Loop_Invariant
           (for all G in File_Index'First .. F =>
              (if Is_Used (T (G)) and then U64 (T (G).Parent) = Dir
               then T (G).Name /= Name));
      end loop;
      Status := Status_Not_Found;
   end Lookup;

   ------------
   -- Create --
   ------------

   procedure Create
     (T : in out Table; O : Owner_Map; D : in out Depth_Map; Dir : U64;
      Name : Name_Array; Kind : U64; File : out U64; Status : out U64)
   is
      Found : U64;
      Found_Status : U64;
      Depth : U8;
      T_Old : constant Table := T with Ghost;
      D_Old : constant Depth_Map := D with Ghost;
   begin
      File := Max_Files;
      Lemma_Step_Same (T);
      if (Kind /= Kind_File and then Kind /= Kind_Dir) or else not Name_Ok (Name) then
         Status := Status_Request;
         return;
      end if;
      Lookup (T, O, D, Dir, Name, Found, Found_Status);
      if Found_Status = Status_Ok then
         --  Dice cuál es el que ya existe.
         File := Found;
         Status := Status_Exists;
         return;
      elsif Found_Status /= Status_Not_Found then
         Status := Found_Status;
         return;
      elsif not Dir_Ok (T, Dir) then
         Status := Status_Not_Found;
         return;
      end if;

      if Dir = Root_Dir then
         Depth := 1;
      elsif D (File_Index (Dir)) >= Max_Depth then
         Status := Status_Full;
         return;
      else
         pragma Assert (Depths_Ok (T, D));
         pragma Assert (D (File_Index (Dir)) >= 1);
         Depth := D (File_Index (Dir)) + 1;
         pragma Assert (Integer (Depth) = Integer (D (File_Index (Dir))) + 1);
      end if;

      for F in File_Index loop
         --  Una entrada libre que no esté retirada.
         if not Is_Used (T (F)) and then T (F).Gen < Gen_Last then
            --  Ninguna entrada en uso tiene a F por directorio.
            pragma Assert
              (for all G in File_Index =>
                 (if Is_Used (T (G)) and then not At_Root (T (G))
                  then T (G).Parent /= U8 (F)));
            pragma Assert (Dir = Root_Dir or else Dir /= U64 (F));
            T (F) :=
              (Used   => 1,
               Kind   => U8 (Kind),
               Parent => U8 (Dir),
               Pad    => 0,
               Length => 0,
               Gen    => T (F).Gen,
               Name   => Name,
               Blocks => (others => 0));
            D (F) := Depth;
            File := U64 (F);
            pragma Assert (Depth_Ok (T, D, F));
            Lemma_Depths_One (T_Old, T, D_Old, D, F);
            Status := Status_Ok;
            pragma Assert (for all G in File_Index => (if G /= F then T (G) = T_Old (G)));
            pragma Assert (T (F).Gen = T_Old (F).Gen);
            pragma Assert (Step_Ok (T_Old, T));
            pragma Assert (Entries_Ok (T));
            pragma Assert (Table_To_Map (T, O));
            pragma Assert (Map_To_Table (T, O));
            pragma Assert (Names_Unique (T));
            pragma Assert (Parents_Ok (T));
            pragma Assert (Depth_Ok (T, D, F));
            pragma Assert (Depths_Ok (T, D));
            return;
         end if;
      end loop;
      Status := Status_Full;
   end Create;

   --------------
   -- Block_Of --
   --------------

   procedure Block_Of
     (T : Table; O : Owner_Map; D : Depth_Map; File, Gen, Slot : U64;
      Block, Bytes : out U64; Status : out U64)
   is
      pragma Unreferenced (O, D);
      L : U64;
   begin
      Block := 0;
      Bytes := 0;
      if File >= Max_Files or else Slot >= File_Blocks then
         Status := Status_Request;
         return;
      end if;
      if not Opened (T, File, Gen) then
         Status := Status_Stale;
         return;
      end if;
      if Is_Dir (T (File_Index (File))) then
         Status := Status_Is_Dir;
         return;
      end if;
      if Integer (Slot) >= Count (T (File_Index (File))) then
         Status := Status_Request;
         return;
      end if;

      pragma Assert (Entry_Ok (T (File_Index (File))));
      pragma Assert (Is_Data (T (File_Index (File)).Blocks (Slot_Index (Slot))));
      Lemma_Count (T (File_Index (File)).Length);
      L := U64 (T (File_Index (File)).Length);
      pragma Assert (L > Slot * Block_Bytes);
      Block := U64 (T (File_Index (File)).Blocks (Slot_Index (Slot)));
      Bytes := L - Slot * Block_Bytes;
      if Bytes > Block_Bytes then
         Bytes := Block_Bytes;
      end if;
      Status := Status_Ok;
   end Block_Of;

   procedure Stat
     (T : Table; O : Owner_Map; D : Depth_Map; File, Gen : U64;
      Kind, Length : out U64; Status : out U64)
   is
      pragma Unreferenced (O, D);
   begin
      Kind := Kind_Dir;
      Length := 0;
      if File = Root_Dir and then Gen = 0 then
         Status := Status_Ok;
         return;
      end if;
      if File >= Max_Files then
         Status := Status_Request;
         return;
      end if;
      if not Opened (T, File, Gen) then
         Status := Status_Stale;
         return;
      end if;
      Kind := U64 (T (File_Index (File)).Kind);
      Length := U64 (T (File_Index (File)).Length);
      Status := Status_Ok;
   end Stat;

   ----------------
   -- Plan_Write --
   ----------------

   procedure Plan_Write
     (T : Table; O : Owner_Map; D : Depth_Map; File, Gen, Slot, Bytes : U64;
      Block : out U64; Status : out U64)
   is
   begin
      Block := 0;
      if File >= Max_Files
        or else Slot >= File_Blocks
        or else Bytes = 0
        or else Bytes > Block_Bytes
      then
         Status := Status_Request;
         return;
      end if;
      if not Opened (T, File, Gen) then
         Status := Status_Stale;
         return;
      end if;
      if Is_Dir (T (File_Index (File))) then
         Status := Status_Is_Dir;
         return;
      end if;
      if Integer (Slot) > Count (T (File_Index (File))) then
         Status := Status_Request;
         return;
      end if;

      --  Siempre un bloque libre, también al reescribir.
      for B in Data_Block loop
         pragma Loop_Invariant (Block = 0);
         if not Owned (O, B) then
            Block := U64 (B);
            Lemma_Free_Unnamed (T, O, D, B);
            Status := Status_Ok;
            return;
         end if;
      end loop;
      Status := Status_Full;
   end Plan_Write;

   ------------------
   -- Commit_Write --
   ------------------

   procedure Commit_Write
     (T : in out Table; O : in out Owner_Map; D : Depth_Map;
      File, Gen, Slot, Bytes, Block : U64; Status : out U64)
   is
      F : File_Index;
      S : Slot_Index;
      Old_Length : U32;
      New_Length : U32;
      Old_Block : Block_Index;
      E_Old : constant Entry_Record := T (File_Index'Min (File_Index'Last, File_Index (File mod Max_Files))) with Ghost;
      T_Old : constant Table := T with Ghost;
      O_Old : constant Owner_Map := O with Ghost;
   begin
      Lemma_Step_Same (T);
      if not Write_Allowed (T, O, File, Gen, Slot, Bytes, Block) then
         Status := Status_Request;
         return;
      end if;
      F := File_Index (File);
      S := Slot_Index (Slot);
      Lemma_Free_Unnamed (T, O, D, Block_Index (Block));
      pragma Assert (E_Old = T (F));
      pragma Assert (Entry_Ok (T (F)));
      Old_Length := T (F).Length;
      Lemma_Count (Old_Length);
      New_Length := U32 (Slot * Block_Bytes + Bytes);
      if New_Length < Old_Length then
         New_Length := Old_Length;
      end if;
      Lemma_Count (New_Length);

      if Integer (S) < Count (T (F)) then
         --  Copia al escribir: el bloque nuevo sustituye al de esa posición,
         --  que queda libre. La cuenta de bloques no cambia.
         pragma Assert (Count_Of (New_Length) = Count_Of (Old_Length));
         pragma Assert (Is_Data (E_Old.Blocks (S)));
         Old_Block := Block_Index (T (F).Blocks (S));
         pragma Assert (Owner_Is (O, Old_Block, F, S));
         pragma Assert (Old_Block /= Block_Index (Block));
         T (F).Blocks (S) := U16 (Block);
         T (F).Length := New_Length;
         pragma Assert (Count (T (F)) = Count (E_Old));
         pragma Assert
           (for all R in Slot_Index =>
              (if R /= S then T (F).Blocks (R) = E_Old.Blocks (R)));
         O (Old_Block) := No_Owner;
         O (Block_Index (Block)) :=
           (Used => 1, File => U8 (F), Slot => U8 (S), Pad => 0);
         --  Nadie más tenía ninguno de los dos bloques.
         pragma Assert
           (for all G in File_Index =>
              (for all R in Slot_Index =>
                 (if In_File (T_Old (G), R) and then (G /= F or else R /= S)
                  then T_Old (G).Blocks (R) /= U16 (Old_Block)
                    and then T_Old (G).Blocks (R) /= U16 (Block))));
         pragma Assert
           (for all B in Block_Index =>
              (if B /= Old_Block and then B /= Block_Index (Block)
               then O (B) = O_Old (B)));
         pragma Assert
           (for all G in File_Index => (if G /= F then T (G) = T_Old (G)));
         pragma Assert
           (for all G in File_Index =>
              (for all R in Slot_Index =>
                 (if In_File (T (G), R) and then (G /= F or else R /= S)
                  then In_File (T_Old (G), R)
                    and then T (G).Blocks (R) = T_Old (G).Blocks (R)
                    and then Owner_Is (O_Old, Block_Index (T (G).Blocks (R)), G, R))));
         pragma Assert (Owner_Is (O, Block_Index (Block), F, S));
         pragma Assert (Table_To_Map (T, O));
         --  Los demás bloques con dueño siguen como estaban, y su dueño no
         --  es la posición que cambió (esa tenía Old_Block).
         pragma Assert
           (for all B in Block_Index =>
              (if Owned (O, B) and then B /= Block_Index (Block)
               then Owned (O_Old, B)
                 and then O (B) = O_Old (B)
                 and then
                   (O_Old (B).File /= U8 (F) or else O_Old (B).Slot /= U8 (S))));
         pragma Assert
           (for all B in Block_Index =>
              (if Owned (O, B) and then B /= Block_Index (Block)
               then T (File_Index (O (B).File)).Blocks (Slot_Index (O (B).Slot))
                 = T_Old (File_Index (O (B).File)).Blocks (Slot_Index (O (B).Slot))));
         pragma Assert (Map_To_Table (T, O));
      else
         --  El bloque siguiente al último, que estaba libre.
         pragma Assert (Count_Of (New_Length) = Integer (S) + 1);
         pragma Assert (Integer (S) = Count (E_Old));
         pragma Assert (E_Old.Blocks (S) = 0);
         T (F).Blocks (S) := U16 (Block);
         T (F).Length := New_Length;
         pragma Assert (Count (T (F)) = Integer (S) + 1);
         pragma Assert
           (for all R in Slot_Index =>
              (if R /= S then T (F).Blocks (R) = E_Old.Blocks (R)));
         O (Block_Index (Block)) :=
           (Used => 1, File => U8 (F), Slot => U8 (S), Pad => 0);
      end if;
      --  El árbol no cambia: ni el uso, ni el tipo, ni el directorio, ni el
      --  nombre de ninguna entrada.
      pragma Assert
        (T (F).Used = E_Old.Used
         and then T (F).Kind = E_Old.Kind
         and then T (F).Gen = E_Old.Gen
         and then T (F).Parent = E_Old.Parent
         and then T (F).Name = E_Old.Name);
      pragma Assert (for all G in File_Index => (if G /= F then T (G) = T_Old (G)));
      pragma Assert (Entry_Ok (T (F)));
      pragma Assert (Entries_Ok (T));
      pragma Assert (Table_To_Map (T, O));
      pragma Assert (Map_To_Table (T, O));
      pragma Assert (Names_Unique (T));
      pragma Assert (Parents_Ok (T));
      Lemma_Depths_Frame (T_Old, T, D);
      pragma Assert (Step_Ok (T_Old, T));
      Status := Status_Ok;
   end Commit_Write;

   ------------
   -- Delete --
   ------------

   procedure Delete
     (T : in out Table; O : in out Owner_Map; D : in out Depth_Map;
      File, Gen : U64; Status : out U64)
   is
      F : File_Index;
      Next_Gen : U32;
      O_Old : constant Owner_Map := O with Ghost;
      T_Old : constant Table := T with Ghost;
      D_Old : constant Depth_Map := D with Ghost;
   begin
      Lemma_Step_Same (T);
      if File >= Max_Files then
         Status := Status_Request;
         return;
      end if;
      F := File_Index (File);
      if not Opened (T, File, Gen) then
         Status := Status_Stale;
         return;
      end if;

      pragma Assert (Entry_Ok (T (F)));

      --  Un directorio, solo vacío.
      if Is_Dir (T (F)) then
         for G in File_Index loop
            if Is_Used (T (G)) and then U64 (T (G).Parent) = File then
               Status := Status_Not_Empty;
               return;
            end if;
            pragma Loop_Invariant
              (for all H in File_Index'First .. G =>
                 (if Is_Used (T (H)) then U64 (T (H).Parent) /= File));
         end loop;
      end if;
      --  Ninguna entrada en uso tiene a F por directorio: si F es un
      --  archivo, porque los directorios de todas son directorios.
      pragma Assert
        (for all G in File_Index =>
           (if Is_Used (T (G)) and then not At_Root (T (G))
            then T (G).Parent /= U8 (F)));

      --  Libera sus bloques; la tabla aún no cambia.
      for S in Slot_Index loop
         exit when Integer (S) >= Count (T (F));
         pragma Assert (Is_Data (T (F).Blocks (S)));
         O (Block_Index (T (F).Blocks (S))) := No_Owner;
         pragma Loop_Invariant
           (for all B in Block_Index =>
              (if Owned (O, B) then O (B) = O_Old (B)));
         pragma Loop_Invariant
           (for all B in Block_Index =>
              (if Owned (O_Old, B) and then O_Old (B).File /= U8 (F)
               then O (B) = O_Old (B)));
         pragma Loop_Invariant
           (for all R in Slot_Index =>
              (if R <= S and then In_File (T (F), R)
               then not Owned (O, Block_Index (T (F).Blocks (R)))));
      end loop;
      pragma Assert
        (for all B in Block_Index =>
           (if Owned (O, B) then O (B).File /= U8 (F)));

      --  La entrada queda libre con la generación siguiente (en uso era
      --  menor que Gen_Last, así que no da la vuelta).
      Next_Gen := T (F).Gen + 1;
      T (F) := Empty_Entry;
      T (F).Gen := Next_Gen;
      D (F) := 0;
      pragma Assert (for all G in File_Index => (if G /= F then T (G) = T_Old (G)));
      pragma Assert (T (F).Gen > T_Old (F).Gen);
      pragma Assert (Step_Ok (T_Old, T));
      pragma Assert (Entries_Ok (T));
      pragma Assert (Table_To_Map (T, O));
      pragma Assert (Map_To_Table (T, O));
      pragma Assert (Names_Unique (T));
      pragma Assert (Parents_Ok (T));
      pragma Assert (Depth_Ok (T, D, F));
      Lemma_Depths_One (T_Old, T, D_Old, D, F);
      Status := Status_Ok;
   end Delete;

   ------------
   -- Rename --
   ------------

   procedure Rename
     (T : in out Table; O : Owner_Map; D : in out Depth_Map;
      File, Gen, Dir : U64; Name : Name_Array; Status : out U64)
   is
      F : File_Index;
      Found : U64;
      Found_Status : U64;
      Old : Entry_Record;
      New_D : Depth_Map;
      Ranked : Boolean;
      T_Old : constant Table := T with Ghost;
   begin
      Lemma_Step_Same (T);
      if File >= Max_Files or else not Name_Ok (Name) then
         Status := Status_Request;
         return;
      end if;
      F := File_Index (File);
      if not Opened (T, File, Gen) then
         Status := Status_Stale;
         return;
      end if;

      Lookup (T, O, D, Dir, Name, Found, Found_Status);
      if Found_Status = Status_Ok then
         --  Renombrar una entrada a su propio nombre no cambia nada; a uno
         --  que ya tiene otra, no la sustituye.
         Status := (if Found = File then Status_Ok else Status_Exists);
         return;
      elsif Found_Status /= Status_Not_Found then
         Status := Found_Status;
         return;
      elsif not Dir_Ok (T, Dir) then
         Status := Status_Not_Found;
         return;
      end if;

      pragma Assert (Depths_Ok (T_Old, D));
      Old := T (F);
      pragma Assert (Entry_Ok (Old));
      T (F).Parent := U8 (Dir);
      T (F).Name := Name;
      pragma Assert (Moved (Old, T (F)));
      pragma Assert (for all G in File_Index => (if G /= F then T (G) = T_Old (G)));

      --  Las profundidades nuevas, desde cero. No salen si el directorio
      --  iba a quedar dentro de sí mismo.
      Rank_All (T, New_D, Ranked);
      if not Ranked then
         T (F) := Old;
         pragma Assert (for all G in File_Index => T (G) = T_Old (G));
         Lemma_Depths_Frame (T_Old, T, D);
         Status := Status_Request;
         return;
      end if;
      D := New_D;
      pragma Assert (Depths_Ok (T, D));

      pragma Assert (Entry_Ok (T (F)));
      pragma Assert (Entries_Ok (T));
      pragma Assert
        (for all S in Slot_Index => In_File (T (F), S) = In_File (Old, S));
      pragma Assert (Table_To_Map (T, O));
      pragma Assert (Map_To_Table (T, O));
      pragma Assert (Names_Unique (T));
      pragma Assert (Is_Used (T (F)) and then T (F).Kind = Old.Kind);
      pragma Assert (Parents_Ok (T));
      pragma Assert (T (F).Gen = Old.Gen);
      pragma Assert (Step_Ok (T_Old, T));
      Status := Status_Ok;
   end Rename;

   -------------
   -- Next_In --
   -------------

   procedure Next_In
     (T : Table; O : Owner_Map; D : Depth_Map; Dir, Gen, From : U64;
      File : out U64; Status : out U64)
   is
      pragma Unreferenced (O, D);
   begin
      File := Max_Files;
      if Dir = Root_Dir then
         if Gen /= 0 then
            Status := Status_Request;
            return;
         end if;
      elsif Dir >= Max_Files then
         Status := Status_Request;
         return;
      elsif not Opened (T, Dir, Gen) then
         Status := Status_Stale;
         return;
      elsif not Is_Dir (T (File_Index (Dir))) then
         Status := Status_Not_Dir;
         return;
      end if;
      Status := Status_Ok;
      for F in File_Index loop
         if U64 (F) >= From and then Is_Used (T (F)) and then U64 (T (F).Parent) = Dir then
            File := U64 (F);
            return;
         end if;
         pragma Loop_Invariant
           (for all G in File_Index'First .. F =>
              (if U64 (G) >= From
               then not Is_Used (T (G)) or else U64 (T (G).Parent) /= Dir));
      end loop;
      File := Max_Files;
   end Next_In;

   -----------------
   -- Free_Blocks --
   -----------------

   function Free_Blocks (O : Owner_Map) return U64 is
      Result : U64 := 0;
   begin
      for B in Data_Block loop
         if not Owned (O, B) then
            Result := Result + 1;
         end if;
         pragma Loop_Invariant (Result <= U64 (B) - First_Data + 1);
      end loop;
      return Result;
   end Free_Blocks;

end Fs_Core;
