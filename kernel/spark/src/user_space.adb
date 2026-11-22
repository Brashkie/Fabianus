--  SPDX-License-Identifier: GPL-3.0-or-later
package body User_Space with
  SPARK_Mode,
  Refined_State =>
    (State => (Pool, Info, Owner, List, Count_Of, Slot_Of, Device_Owner, Attached, Kernel, Pool_Ppn, Frame_Base, Frame_Count, Ready))
is
   use type Frame_Gate.U64;

   Max_Frames : constant := 32768;

   --  Cada tabla tiene un nivel fijo, así que la estructura no puede tener ciclos.
   type Table_Slot is range 0 .. 7;
   subtype Mid_Slot is Table_Slot range 1 .. 2;
   subtype Leaf_Slot is Table_Slot range 3 .. 7;

   Tables_Per_Space : constant U64 := 8;

   type Mid_Total is range 0 .. 2;
   type Leaf_Total is range 0 .. 5;

   type Space_Tables is array (Table_Slot) of Page_Table;
   type Space_Pool is array (Space_Id) of Space_Tables;

   type Space_Info is record
      Active    : Boolean;
      Mid_Used  : Mid_Total;
      Leaf_Used : Leaf_Total;
   end record;

   type Info_Array is array (Space_Id) of Space_Info;

   type Frame_Number is range 0 .. Max_Frames - 1;
   type Owner_Map is array (Frame_Number) of Owner_Tag;

   --  Qué espacios están unidos a cada región.
   type Attach_Map is array (Region_Tag, Space_Id) of Boolean;

   --  Lo que un espacio puede tener mapeado además de sus marcos: el
   --  dispositivo, si es suyo, y las regiones a las que está unido.
   type Access_Rights is record
      Dev   : Device_Map;
      Links : Attach_Map;
   end record;

   Empty_Tables : constant Space_Tables := (others => (others => 0));
   Empty_Info   : constant Space_Info :=
     (Active => False, Mid_Used => 0, Leaf_Used => 0);

   Pool : Space_Pool := (others => (others => (others => 0))) with
     Export,
     Convention    => C,
     External_Name => "fb_user_pool",
     Alignment     => 4096;

   Info : Info_Array := (others => (False, 0, 0));
   Owner : Owner_Map := (others => 0);

   --  Lista de los marcos de cada espacio, y la posición de cada marco en la
   --  lista de su dueño. Destroy recorre exactamente esa lista: su coste es lo
   --  que tiene el proceso, no el tamaño de la memoria. Cabe un marco por cada
   --  entrada de las cinco tablas hoja.
   Max_Owned : constant := 5 * 512;
   type Owned_Count is range 0 .. Max_Owned;
   subtype Owned_Index is Owned_Count range 1 .. Max_Owned;
   type Frame_List is array (Owned_Index) of Frame_Number;
   type List_Map is array (Holder_Id) of Frame_List;
   type Count_Map is array (Holder_Id) of Owned_Count;
   type Slot_Map is array (Frame_Number) of Owned_Count;

   List     : List_Map := (others => (others => 0));
   Count_Of : Count_Map := (others => 0);
   Slot_Of  : Slot_Map := (others => 0);
   Device_Owner : Device_Map := (others => No_Owner);
   Attached : Attach_Map := (others => (others => False));
   Kernel : Kernel_Root := (others => 0);
   Pool_Ppn : U64 := 0;
   Frame_Base : U64 := 0;
   Frame_Count : U64 := 0;
   Ready : Boolean := False;

   function Root_Index (Va : U64) return Entry_Index is
     (Entry_Index (Va / 2**30))
   with Pre => In_User_Window (Va);

   function Mid_Index (Va : U64) return Entry_Index is
     (Entry_Index ((Va / 2**21) and 511));

   function Low_Index (Va : U64) return Entry_Index is
     (Entry_Index ((Va / 2**12) and 511));

   function Table_Ppn (Base : U64; S : Space_Id; T : Table_Slot) return U64 is
     (Base + U64 (S - 1) * Tables_Per_Space + U64 (T));

   function Points_Into
     (E     : U64;
      Base  : U64;
      S     : Space_Id;
      First : Table_Slot;
      Count : U64) return Boolean
   is
     (E < 2**54
      and then Is_Table (E)
      and then Ppn_Of (E) >= Table_Ppn (Base, S, First)
      and then Ppn_Of (E) - Table_Ppn (Base, S, First) < Count)
   with Ghost;

   function Frame_In (Ppn, Base, Count : U64) return Boolean is
     (Ppn >= Base and then Ppn - Base < Count);

   function Is_Zero (T : Space_Tables) return Boolean is
     (for all X in Table_Slot => (for all E in Entry_Index => T (X) (E) = 0))
   with Ghost;

   --  Forma de las tablas. Su definición solo se abre dentro de los lemas: así
   --  el resto de comprobaciones no arrastra los cuantificadores.
   function Structure_Ok
     (T    : Space_Tables;
      I    : Space_Info;
      Base : U64;
      S    : Space_Id;
      K    : Kernel_Root) return Boolean
   is
     (if not I.Active
      then Is_Zero (T) and then I.Mid_Used = 0 and then I.Leaf_Used = 0
      else
        (for all E in Entry_Index =>
           (if E <= 3
            then T (0) (E) = K (Kernel_Root_Index (E))
            elsif E <= 255
            then T (0) (E) = 0
                 or else Points_Into (T (0) (E), Base, S, 1, U64 (I.Mid_Used))
            else T (0) (E) = 0))
        and then
        (for all X in Mid_Slot =>
           (for all E in Entry_Index =>
              (if U64 (X) - 1 < U64 (I.Mid_Used)
               then T (X) (E) = 0
                    or else Points_Into (T (X) (E), Base, S, 3, U64 (I.Leaf_Used))
               else T (X) (E) = 0)))
        and then
        (for all X in Leaf_Slot =>
           (for all E in Entry_Index =>
              (if U64 (X) - 3 < U64 (I.Leaf_Used)
               then T (X) (E) = 0 or else Is_User_Leaf (T (X) (E))
               else T (X) (E) = 0))))
   with
     Ghost,
     Annotate => (GNATprove, Hide_Info, "Expression_Function_Body");

   --  S puede usar un marco de este dueño: es S, o una región a la que S está
   --  unido.
   function Uses (Tag : Owner_Tag; S : Space_Id; Dev : Access_Rights) return Boolean is
     (Tag = S or else (Tag in Region_Tag and then Dev.Links (Tag, S)))
   with Ghost;

   --  Página que S puede tener mapeada: un marco suyo o de una región a la que
   --  está unido, o el dispositivo si es suyo.
   function Owned_Ppn
     (Ppn   : U64;
      S     : Space_Id;
      Base  : U64;
      Count : U64;
      O     : Owner_Map;
      Dev   : Access_Rights) return Boolean
   is
     ((for some D in Device_Id => Ppn = Device_Ppn (D) and then Dev.Dev (D) = S)
      or else
        (Frame_In (Ppn, Base, Count)
         and then Ppn - Base < U64 (Max_Frames)
         and then Uses (O (Frame_Number (Ppn - Base)), S, Dev)))
   with Ghost;

   --  Cada hoja apunta a una página cuyo dueño es este espacio.
   function Frames_Owned
     (T     : Space_Tables;
      S     : Space_Id;
      Base  : U64;
      Count : U64;
      O     : Owner_Map;
      Dev : Access_Rights) return Boolean
   is
     (for all X in Leaf_Slot =>
        (for all E in Entry_Index =>
           (if T (X) (E) /= 0
            then Owned_Ppn (Ppn_Of (T (X) (E)), S, Base, Count, O, Dev))))
   with
     Ghost,
     Annotate => (GNATprove, Hide_Info, "Expression_Function_Body");

   function Rights return Access_Rights is
     (Access_Rights'(Dev => Device_Owner, Links => Attached))
   with Ghost;

   function Kernel_Entry_Ok (E : U64) return Boolean is
     (E = 0 or else (E < 2**54 and then Is_Table (E)));

   function Bounds_Ok return Boolean is
     (Pool_Ppn <= Max_Base_Ppn
      and then Frame_Base <= Max_Base_Ppn
      and then Frame_Count <= U64 (Max_Frames)
      and then (for all D in Device_Id => not Frame_In (Device_Ppn (D), Frame_Base, Frame_Count))
      and then
        (if Ready
         then Frame_Count >= 1
           and then Pool_Ppn + U64 (Max_Spaces) * Tables_Per_Space <= Frame_Base
           and then (for all I in Kernel_Root_Index => Kernel_Entry_Ok (Kernel (I)))
         else (for all S in Space_Id => not Info (S).Active)))
   with Ghost;

   --  Las listas y los dueños se corresponden uno a uno: todo marco con dueño
   --  está en la lista de su dueño, en su posición, y toda entrada de una lista
   --  es un marco de ese espacio en esa posición.
   function Lists_Ok return Boolean is
     ((for all F in Frame_Number =>
         (if Owner (F) /= No_Owner
          then Slot_Of (F) in 1 .. Count_Of (Owner (F))
            and then List (Owner (F)) (Slot_Of (F)) = F))
      and then
        (for all S in Holder_Id =>
           (for all I in 1 .. Count_Of (S) =>
              Owner (List (S) (I)) = S and then Slot_Of (List (S) (I)) = I)))
   with
     Ghost,
     Annotate => (GNATprove, Hide_Info, "Expression_Function_Body");

   --  Una región sin marcos no existe: nadie está unido a ella. Y ninguna
   --  pasa de Max_Region_Pages.
   function Regions_Ok return Boolean is
     (for all R in Region_Tag =>
        Count_Of (R) <= Max_Region_Pages
        and then (if Count_Of (R) = 0 then (for all S in Space_Id => not Attached (R, S))))
   with Ghost;

   function Invariant return Boolean is
     (Bounds_Ok
      and then Lists_Ok
      and then Regions_Ok
      and then
        (for all S in Space_Id =>
           Structure_Ok (Pool (S), Info (S), Pool_Ppn, S, Kernel)
           and then Frames_Owned (Pool (S), S, Frame_Base, Frame_Count, Owner, Rights)));

   function Own_Table (E : U64; S : Space_Id) return Boolean is
     (Is_Table (E)
      and then Ppn_Of (E) >= Table_Ppn (Pool_Ppn, S, 0)
      and then Ppn_Of (E) - Table_Ppn (Pool_Ppn, S, 0) < Tables_Per_Space);

   function Child_Slot (E : U64; S : Space_Id) return Table_Slot is
     (Table_Slot (Ppn_Of (E) - Table_Ppn (Pool_Ppn, S, 0)))
   with Pre => Own_Table (E, S);

   function Walk (S : Space_Id; Va : U64) return U64 is
     (if not Own_Table (Pool (S) (0) (Root_Index (Va)), S)
      then 0
      elsif not Own_Table
                  (Pool (S) (Child_Slot (Pool (S) (0) (Root_Index (Va)), S)) (Mid_Index (Va)),
                   S)
      then 0
      else Pool (S)
             (Child_Slot
                (Pool (S) (Child_Slot (Pool (S) (0) (Root_Index (Va)), S)) (Mid_Index (Va)),
                 S))
             (Low_Index (Va)));

   function Frame_Owner_Is (Ppn : U64; S : Space_Id) return Boolean is
     (Owned_Ppn (Ppn, S, Frame_Base, Frame_Count, Owner, Rights));
   pragma Annotate (GNATprove, Hide_Info, "Expression_Function_Body", Frame_Owner_Is);

   function No_Frames_Owned (S : Space_Id) return Boolean is
     (for all F in Frame_Number =>
        (if U64 (F) < Frame_Count then Owner (F) /= S));

   function Device_Holders return Device_Map is (Device_Owner);

   function Attached_To (R : Region_Tag; S : Space_Id) return Boolean is (Attached (R, S));

   function Shared_By (Ppn : U64; A, B : Space_Id) return Boolean is
     (Frame_In (Ppn, Frame_Base, Frame_Count)
      and then Ppn - Frame_Base < U64 (Max_Frames)
      and then Owner (Frame_Number (Ppn - Frame_Base)) in Region_Tag
      and then Attached (Owner (Frame_Number (Ppn - Frame_Base)), A)
      and then Attached (Owner (Frame_Number (Ppn - Frame_Base)), B));

   function Private_To (Ppn : U64; S : Space_Id) return Boolean is
     (Frame_In (Ppn, Frame_Base, Frame_Count)
      and then Ppn - Frame_Base < U64 (Max_Frames)
      and then Owner (Frame_Number (Ppn - Frame_Base)) = S);

   function Pages_Of (R : Region_Tag) return U64 is (U64 (Count_Of (R)));

   ---------------------------------------------------------------------------
   --  Lemas. Cada uno recibe por parámetro solo lo que necesita.
   ---------------------------------------------------------------------------

   --  T2 es igual que T salvo, como mucho, en la entrada (Table, Index).
   function Only_Changed
     (T, T2 : Space_Tables;
      Table : Table_Slot;
      Index : Entry_Index) return Boolean
   is
     (for all X in Table_Slot =>
        (for all E in Entry_Index =>
           (if X /= Table or else E /= Index then T2 (X) (E) = T (X) (E))))
   with Ghost;

   procedure Lemma_User_Leaf (Ppn : U64; Perm : Permission) with
     Ghost,
     Global => null,
     Pre    => Ppn < Max_Ppn,
     Post   =>
       User_Leaf (Ppn, Perm) /= 0
       and then Is_User_Leaf (User_Leaf (Ppn, Perm))
       and then Ppn_Of (User_Leaf (Ppn, Perm)) = Ppn
   is
   begin
      null;
   end Lemma_User_Leaf;

   procedure Lemma_Page_Address (Ppn : U64) with
     Ghost,
     Global => null,
     Pre    => Ppn < Max_Ppn,
     Post   =>
       (Ppn * Page_Bytes) mod Page_Bytes = 0
       and then (Ppn * Page_Bytes) / Page_Bytes = Ppn
   is
   begin
      null;
   end Lemma_Page_Address;

   procedure Lemma_New_Pointer (Ppn : U64) with
     Ghost,
     Global => null,
     Pre    => Ppn < Max_Ppn,
     Post   =>
       Table_Entry (Ppn) < 2**54
       and then Is_Table (Table_Entry (Ppn))
       and then Ppn_Of (Table_Entry (Ppn)) = Ppn
   is
   begin
      null;
   end Lemma_New_Pointer;

   procedure Lemma_Zero_Is_Ok
     (T : Space_Tables; I : Space_Info; Base : U64; S : Space_Id; K : Kernel_Root)
   with
     Ghost,
     Global => null,
     Pre    => Is_Zero (T) and then not I.Active and then I.Mid_Used = 0 and then I.Leaf_Used = 0,
     Post   => Structure_Ok (T, I, Base, S, K)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      null;
   end Lemma_Zero_Is_Ok;

   procedure Lemma_Inactive_Is_Zero
     (T : Space_Tables; I : Space_Info; Base : U64; S : Space_Id; K : Kernel_Root)
   with
     Ghost,
     Global => null,
     Pre    => Structure_Ok (T, I, Base, S, K) and then not I.Active,
     Post   => Is_Zero (T) and then I.Mid_Used = 0 and then I.Leaf_Used = 0
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      null;
   end Lemma_Inactive_Is_Zero;

   procedure Lemma_Zero_Owns_Nothing
     (T : Space_Tables; S : Space_Id; Base, Count : U64; O : Owner_Map;
      Dev : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    => Is_Zero (T),
     Post   => Frames_Owned (T, S, Base, Count, O, Dev)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frames_Owned);
   begin
      null;
   end Lemma_Zero_Owns_Nothing;

   --  Leer una entrada raíz de usuario.
   procedure Lemma_Root_Entry
     (T     : Space_Tables;
      I     : Space_Info;
      Base  : U64;
      S     : Space_Id;
      K     : Kernel_Root;
      Index : Entry_Index)
   with
     Ghost,
     Global => null,
     Pre    => Structure_Ok (T, I, Base, S, K) and then Index in 4 .. 255,
     Post   =>
       T (0) (Index) = 0
       or else
         (I.Active and then Points_Into (T (0) (Index), Base, S, 1, U64 (I.Mid_Used)))
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      null;
   end Lemma_Root_Entry;

   procedure Lemma_Mid_Entry
     (T     : Space_Tables;
      I     : Space_Info;
      Base  : U64;
      S     : Space_Id;
      K     : Kernel_Root;
      Mid   : Mid_Slot;
      Index : Entry_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Structure_Ok (T, I, Base, S, K)
       and then I.Active
       and then U64 (Mid) - 1 < U64 (I.Mid_Used),
     Post   =>
       T (Mid) (Index) = 0
       or else Points_Into (T (Mid) (Index), Base, S, 3, U64 (I.Leaf_Used))
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      null;
   end Lemma_Mid_Entry;

   procedure Lemma_Leaf_Entry
     (T     : Space_Tables;
      I     : Space_Info;
      Base  : U64;
      S     : Space_Id;
      K     : Kernel_Root;
      Leaf  : Leaf_Slot;
      Index : Entry_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Structure_Ok (T, I, Base, S, K)
       and then I.Active
       and then U64 (Leaf) - 3 < U64 (I.Leaf_Used),
     Post   => T (Leaf) (Index) = 0 or else Is_User_Leaf (T (Leaf) (Index))
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      null;
   end Lemma_Leaf_Entry;

   procedure Lemma_Owned_Entry
     (T     : Space_Tables;
      S     : Space_Id;
      Base  : U64;
      Count : U64;
      O     : Owner_Map;
      Leaf  : Leaf_Slot;
      Index : Entry_Index;
      Dev : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    => Frames_Owned (T, S, Base, Count, O, Dev) and then T (Leaf) (Index) /= 0,
     Post   => Owned_Ppn (Ppn_Of (T (Leaf) (Index)), S, Base, Count, O, Dev)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frames_Owned);
   begin
      null;
   end Lemma_Owned_Entry;

   --  Activar un espacio vacío: solo se copian las entradas del kernel.
   procedure Lemma_Activate
     (T, T2 : Space_Tables;
      I2    : Space_Info;
      Base  : U64;
      S     : Space_Id;
      K     : Kernel_Root)
   with
     Ghost,
     Global => null,
     Pre    =>
       Is_Zero (T)
       and then I2.Active
       and then I2.Mid_Used = 0
       and then I2.Leaf_Used = 0
       and then
         (for all X in Table_Slot =>
            (for all E in Entry_Index =>
               (if X /= 0 or else E > 3 then T2 (X) (E) = T (X) (E))))
       and then (for all E in Entry_Index range 0 .. 3 => T2 (0) (E) = K (Kernel_Root_Index (E))),
     Post   => Structure_Ok (T2, I2, Base, S, K)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      null;
   end Lemma_Activate;

   procedure Lemma_Add_Mid
     (T, T2 : Space_Tables;
      I, I2 : Space_Info;
      Base  : U64;
      S     : Space_Id;
      K     : Kernel_Root;
      Index : Entry_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Base <= Max_Base_Ppn
       and then Structure_Ok (T, I, Base, S, K)
       and then I.Active
       and then I.Mid_Used < 2
       and then Index in 4 .. 255
       and then I2.Active
       and then U64 (I2.Mid_Used) = U64 (I.Mid_Used) + 1
       and then I2.Leaf_Used = I.Leaf_Used
       and then Only_Changed (T, T2, 0, Index)
       and then T2 (0) (Index) =
                  Table_Entry (Table_Ppn (Base, S, 1 + Table_Slot (I.Mid_Used))),
     Post   => Structure_Ok (T2, I2, Base, S, K)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      Lemma_New_Pointer (Table_Ppn (Base, S, 1 + Table_Slot (I.Mid_Used)));
   end Lemma_Add_Mid;

   procedure Lemma_Add_Leaf
     (T, T2 : Space_Tables;
      I, I2 : Space_Info;
      Base  : U64;
      S     : Space_Id;
      K     : Kernel_Root;
      Mid   : Mid_Slot;
      Index : Entry_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Base <= Max_Base_Ppn
       and then Structure_Ok (T, I, Base, S, K)
       and then I.Active
       and then I.Leaf_Used < 5
       and then U64 (Mid) - 1 < U64 (I.Mid_Used)
       and then I2.Active
       and then U64 (I2.Leaf_Used) = U64 (I.Leaf_Used) + 1
       and then I2.Mid_Used = I.Mid_Used
       and then Only_Changed (T, T2, Mid, Index)
       and then T2 (Mid) (Index) =
                  Table_Entry (Table_Ppn (Base, S, 3 + Table_Slot (I.Leaf_Used))),
     Post   => Structure_Ok (T2, I2, Base, S, K)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      Lemma_New_Pointer (Table_Ppn (Base, S, 3 + Table_Slot (I.Leaf_Used)));
   end Lemma_Add_Leaf;

   procedure Lemma_Install_Structure
     (T, T2 : Space_Tables;
      I     : Space_Info;
      Base  : U64;
      S     : Space_Id;
      K     : Kernel_Root;
      Leaf  : Leaf_Slot;
      Index : Entry_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Structure_Ok (T, I, Base, S, K)
       and then I.Active
       and then U64 (Leaf) - 3 < U64 (I.Leaf_Used)
       and then Only_Changed (T, T2, Leaf, Index)
       and then Is_User_Leaf (T2 (Leaf) (Index)),
     Post   => Structure_Ok (T2, I, Base, S, K)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      null;
   end Lemma_Install_Structure;

   --  Frames_Owned solo mira las tablas hoja.
   procedure Lemma_Same_Leaves
     (T, T2 : Space_Tables;
      S     : Space_Id;
      Base  : U64;
      Count : U64;
      O     : Owner_Map;
      Dev : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       Frames_Owned (T, S, Base, Count, O, Dev)
       and then (for all X in Leaf_Slot => T2 (X) = T (X)),
     Post   => Frames_Owned (T2, S, Base, Count, O, Dev)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frames_Owned);
   begin
      null;
   end Lemma_Same_Leaves;

   --  Cambiar el dueño de un marco que no era de S no afecta a las hojas de S.
   procedure Lemma_Other_Owner
     (T     : Space_Tables;
      S     : Space_Id;
      Base  : U64;
      Count : U64;
      O, O2 : Owner_Map;
      F     : Frame_Number;
      Dev : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       Frames_Owned (T, S, Base, Count, O, Dev)
       and then not Uses (O (F), S, Dev)
       and then (for all G in Frame_Number => (if G /= F then O2 (G) = O (G))),
     Post   => Frames_Owned (T, S, Base, Count, O2, Dev)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frames_Owned);
   begin
      null;
   end Lemma_Other_Owner;

   --  El mismo paso para todos los espacios salvo S (S puede ser una región:
   --  entonces para todos).
   procedure Lemma_Other_Owners
     (Tables : Space_Pool;
      S      : Owner_Tag;
      Base   : U64;
      Count  : U64;
      O, O2  : Owner_Map;
      F      : Frame_Number;
      Dev : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       (for all X in Space_Id =>
          (if X /= S then Frames_Owned (Tables (X), X, Base, Count, O, Dev)))
       and then (for all X in Space_Id => (if X /= S then not Uses (O (F), X, Dev)))
       and then (for all G in Frame_Number => (if G /= F then O2 (G) = O (G))),
     Post   =>
       (for all X in Space_Id =>
          (if X /= S then Frames_Owned (Tables (X), X, Base, Count, O2, Dev)))
   is
   begin
      for X in Space_Id loop
         if X /= S then
            Lemma_Other_Owner (Tables (X), X, Base, Count, O, O2, F, Dev);
         end if;
         pragma Loop_Invariant
           (for all Y in Space_Id =>
              (if Y <= X and then Y /= S
               then Frames_Owned (Tables (Y), Y, Base, Count, O2, Dev)));
      end loop;
   end Lemma_Other_Owners;

   procedure Lemma_Install_Owned
     (T, T2 : Space_Tables;
      S     : Space_Id;
      Base  : U64;
      Count : U64;
      O     : Owner_Map;
      Leaf  : Leaf_Slot;
      Index : Entry_Index;
      Ppn   : U64;
      Dev : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       Frames_Owned (T, S, Base, Count, O, Dev)
       and then Only_Changed (T, T2, Leaf, Index)
       and then Owned_Ppn (Ppn, S, Base, Count, O, Dev)
       and then Ppn_Of (T2 (Leaf) (Index)) = Ppn,
     Post   => Frames_Owned (T2, S, Base, Count, O, Dev)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frames_Owned);
   begin
      null;
   end Lemma_Install_Owned;

   --  Si el dispositivo no era de S, S no lo tenía mapeado: da igual quién lo tenga.
   procedure Lemma_Device_Change
     (T       : Space_Tables;
      S       : Space_Id;
      Base    : U64;
      Count   : U64;
      O       : Owner_Map;
      Dev     : Access_Rights;
      Dev2    : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       Frames_Owned (T, S, Base, Count, O, Dev)
       and then (for all E in Device_Id => (if Dev.Dev (E) = S then Dev2.Dev (E) = S))
       and then Dev2.Links = Dev.Links,
     Post   => Frames_Owned (T, S, Base, Count, O, Dev2)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frames_Owned);
   begin
      null;
   end Lemma_Device_Change;

   procedure Lemma_Device_Others
     (Tables : Space_Pool;
      S      : Space_Id;
      Base   : U64;
      Count  : U64;
      O      : Owner_Map;
      Dev    : Access_Rights;
      Dev2   : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       (for all X in Space_Id =>
          (if X /= S then Frames_Owned (Tables (X), X, Base, Count, O, Dev)))
       --  Solo cambian dispositivos que eran de S o de nadie, y pasan a S o a nadie.
       and then
         (for all E in Device_Id =>
            Dev2.Dev (E) = Dev.Dev (E)
            or else
              ((Dev.Dev (E) = S or else Dev.Dev (E) = No_Owner)
               and then (Dev2.Dev (E) = S or else Dev2.Dev (E) = No_Owner)))
       and then Dev2.Links = Dev.Links,
     Post   =>
       (for all X in Space_Id =>
          (if X /= S then Frames_Owned (Tables (X), X, Base, Count, O, Dev2)))
   is
   begin
      for X in Space_Id loop
         if X /= S then
            Lemma_Device_Change (Tables (X), X, Base, Count, O, Dev, Dev2);
         end if;
         pragma Loop_Invariant
           (for all Y in Space_Id =>
              (if Y <= X and then Y /= S
               then Frames_Owned (Tables (Y), Y, Base, Count, O, Dev2)));
      end loop;
   end Lemma_Device_Others;

   --  Más uniones (o las mismas) para S: S sigue teniendo solo lo que puede usar.
   procedure Lemma_Links_Grow
     (T     : Space_Tables;
      S     : Space_Id;
      Base  : U64;
      Count : U64;
      O     : Owner_Map;
      Dev   : Access_Rights;
      Dev2  : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       Frames_Owned (T, S, Base, Count, O, Dev)
       and then Dev2.Dev = Dev.Dev
       and then (for all R in Region_Tag => (if Dev.Links (R, S) then Dev2.Links (R, S))),
     Post   => Frames_Owned (T, S, Base, Count, O, Dev2)
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frames_Owned);
   begin
      null;
   end Lemma_Links_Grow;

   --  Lo mismo para todos los espacios salvo S (S puede ser una región:
   --  entonces para todos).
   procedure Lemma_Links_Others
     (Tables : Space_Pool;
      S      : Owner_Tag;
      Base   : U64;
      Count  : U64;
      O      : Owner_Map;
      Dev    : Access_Rights;
      Dev2   : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       (for all X in Space_Id =>
          (if X /= S then Frames_Owned (Tables (X), X, Base, Count, O, Dev)))
       and then Dev2.Dev = Dev.Dev
       and then
         (for all X in Space_Id =>
            (if X /= S
             then (for all R in Region_Tag => (if Dev.Links (R, X) then Dev2.Links (R, X))))),
     Post   =>
       (for all X in Space_Id =>
          (if X /= S then Frames_Owned (Tables (X), X, Base, Count, O, Dev2)))
   is
   begin
      for X in Space_Id loop
         if X /= S then
            Lemma_Links_Grow (Tables (X), X, Base, Count, O, Dev, Dev2);
         end if;
         pragma Loop_Invariant
           (for all Y in Space_Id =>
              (if Y <= X and then Y /= S
               then Frames_Owned (Tables (Y), Y, Base, Count, O, Dev2)));
      end loop;
   end Lemma_Links_Others;

   ---------------------------------------------------------------------------

   procedure Lemma_Walk_Owned (S : Space_Id; Va : U64) is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frame_Owner_Is);
      T : constant Space_Tables := Pool (S);
      I : constant Space_Info := Info (S);
      Top : constant U64 := T (0) (Root_Index (Va));
      Mid : Table_Slot;
      Next : U64;
      Leaf : Table_Slot;
   begin
      pragma Assert (Structure_Ok (T, I, Pool_Ppn, S, Kernel));
      pragma Assert (Frames_Owned (T, S, Frame_Base, Frame_Count, Owner, Rights));
      pragma Assert (Root_Index (Va) in 4 .. 255);

      Lemma_Root_Entry (T, I, Pool_Ppn, S, Kernel, Root_Index (Va));
      pragma Assert (Top /= 0);
      Mid := Child_Slot (Top, S);
      pragma Assert (Mid in Mid_Slot and then U64 (Mid) - 1 < U64 (I.Mid_Used));

      Lemma_Mid_Entry (T, I, Pool_Ppn, S, Kernel, Mid, Mid_Index (Va));
      Next := T (Mid) (Mid_Index (Va));
      pragma Assert (Next /= 0);
      Leaf := Child_Slot (Next, S);
      pragma Assert (Leaf in Leaf_Slot and then U64 (Leaf) - 3 < U64 (I.Leaf_Used));

      pragma Assert (T (Leaf) (Low_Index (Va)) = Walk (S, Va));
      Lemma_Leaf_Entry (T, I, Pool_Ppn, S, Kernel, Leaf, Low_Index (Va));
      Lemma_Owned_Entry (T, S, Frame_Base, Frame_Count, Owner, Leaf, Low_Index (Va), Rights);
   end Lemma_Walk_Owned;

   procedure Lemma_Isolation (A, B : Space_Id; Va_A, Va_B : U64) is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frame_Owner_Is);
   begin
      Lemma_Walk_Owned (A, Va_A);
      Lemma_Walk_Owned (B, Va_B);
   end Lemma_Isolation;

   procedure Lemma_Private (A, B : Space_Id; Va_A, Va_B : U64) is
   begin
      Lemma_Isolation (A, B, Va_A, Va_B);
   end Lemma_Private;

   --  Antes de Init no hay espacios activos: nada depende de los valores que fija.
   procedure Lemma_Rebase
     (Tables   : Space_Pool;
      Infos    : Info_Array;
      Old_Base : U64;
      New_Base : U64;
      New_Frame_Base  : U64;
      New_Frame_Count : U64;
      O        : Owner_Map;
      Old_K    : Kernel_Root;
      New_K    : Kernel_Root;
      Dev : Access_Rights)
   with
     Ghost,
     Global => null,
     Pre    =>
       (for all X in Space_Id =>
          not Infos (X).Active
          and then Structure_Ok (Tables (X), Infos (X), Old_Base, X, Old_K)),
     Post   =>
       (for all X in Space_Id =>
          Structure_Ok (Tables (X), Infos (X), New_Base, X, New_K)
          and then Frames_Owned (Tables (X), X, New_Frame_Base, New_Frame_Count, O, Dev))
   is
   begin
      for X in Space_Id loop
         Lemma_Inactive_Is_Zero (Tables (X), Infos (X), Old_Base, X, Old_K);
         Lemma_Zero_Is_Ok (Tables (X), Infos (X), New_Base, X, New_K);
         Lemma_Zero_Owns_Nothing (Tables (X), X, New_Frame_Base, New_Frame_Count, O, Dev);
         pragma Loop_Invariant
           (for all Y in Space_Id =>
              (if Y <= X
               then Structure_Ok (Tables (Y), Infos (Y), New_Base, Y, New_K)
                 and then Frames_Owned (Tables (Y), Y, New_Frame_Base, New_Frame_Count, O, Dev)));
      end loop;
   end Lemma_Rebase;

   --  El estado inicial cumple la invariante: todo está a cero.
   procedure Lemma_Initial_State with
     Ghost,
     Global => (Input => (Pool, Info, Owner, Device_Owner, Attached, Kernel, Pool_Ppn, Frame_Base, Frame_Count)),
     Pre    =>
       (for all X in Space_Id =>
          Is_Zero (Pool (X))
          and then not Info (X).Active
          and then Info (X).Mid_Used = 0
          and then Info (X).Leaf_Used = 0),
     Post   =>
       (for all X in Space_Id =>
          Structure_Ok (Pool (X), Info (X), Pool_Ppn, X, Kernel)
          and then Frames_Owned (Pool (X), X, Frame_Base, Frame_Count, Owner, Rights))
   is
   begin
      for X in Space_Id loop
         Lemma_Zero_Is_Ok (Pool (X), Info (X), Pool_Ppn, X, Kernel);
         Lemma_Zero_Owns_Nothing (Pool (X), X, Frame_Base, Frame_Count, Owner, Rights);
         pragma Loop_Invariant
           (for all Y in Space_Id =>
              (if Y <= X
               then Structure_Ok (Pool (Y), Info (Y), Pool_Ppn, Y, Kernel)
                 and then Frames_Owned (Pool (Y), Y, Frame_Base, Frame_Count, Owner, Rights)));
      end loop;
   end Lemma_Initial_State;

   --  Sin ningún marco con dueño y con las listas vacías, todo cuadra.
   procedure Lemma_No_Owner_Lists with
     Ghost,
     Global => (Proof_In => (Owner, List, Count_Of, Slot_Of)),
     Pre    =>
       (for all F in Frame_Number => Owner (F) = No_Owner)
       and then (for all S in Holder_Id => Count_Of (S) = 0),
     Post   => Lists_Ok
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Lists_Ok);
   begin
      null;
   end Lemma_No_Owner_Lists;

   function Init
     (Pool_Address : U64;
      First_Frame  : U64;
      Count        : U64;
      Entries      : Kernel_Root) return U64
   is
      Old_Base : constant U64 := Pool_Ppn with Ghost;
      Old_K    : constant Kernel_Root := Kernel with Ghost;
   begin
      if Ready
        or else Pool_Address mod Page_Bytes /= 0
        or else First_Frame mod Page_Bytes /= 0
        or else Pool_Address / Page_Bytes > Max_Base_Ppn
        or else First_Frame / Page_Bytes > Max_Base_Ppn
        or else Count = 0
        or else Count > U64 (Max_Frames)
        or else Frame_In (Device_Ppn (0), First_Frame / Page_Bytes, Count)
        or else Frame_In (Device_Ppn (1), First_Frame / Page_Bytes, Count)
        or else Pool_Address / Page_Bytes + U64 (Max_Spaces) * Tables_Per_Space
                  > First_Frame / Page_Bytes
        or else (for some I in Kernel_Root_Index => not Kernel_Entry_Ok (Entries (I)))
      then
         return Status_Invalid;
      end if;

      Pool_Ppn    := Pool_Address / Page_Bytes;
      Frame_Base  := First_Frame / Page_Bytes;
      Frame_Count := Count;
      Kernel      := Entries;
      Ready       := True;

      Lemma_Rebase
        (Pool, Info, Old_Base, Pool_Ppn, Frame_Base, Frame_Count, Owner, Old_K, Kernel, Rights);
      return Status_Ok;
   end Init;

   function Create return U64 is
      Found : Owner_Tag := No_Owner;
   begin
      if not Ready then
         return 0;
      end if;

      for S in Space_Id loop
         pragma Loop_Invariant (Found = No_Owner);
         if not Info (S).Active then
            Found := S;
            exit;
         end if;
      end loop;

      if Found = No_Owner then
         return 0;
      end if;

      declare
         Old_T : constant Space_Tables := Pool (Found) with Ghost;
         Old_I : constant Space_Info := Info (Found) with Ghost;
      begin
         Lemma_Inactive_Is_Zero (Old_T, Old_I, Pool_Ppn, Found, Kernel);

         Pool (Found) (0) (0) := Kernel (0);
         Pool (Found) (0) (1) := Kernel (1);
         Pool (Found) (0) (2) := Kernel (2);
         Pool (Found) (0) (3) := Kernel (3);
         Info (Found).Active := True;

         Lemma_Activate (Old_T, Pool (Found), Info (Found), Pool_Ppn, Found, Kernel);
         Lemma_Same_Leaves
           (Old_T, Pool (Found), Found, Frame_Base, Frame_Count, Owner, Rights);
      end;
      return U64 (Found);
   end Create;

   function Root_Ppn (Space : U64) return U64 is
   begin
      if not Valid_Space (Space) or else not Info (Owner_Tag (Space)).Active then
         return 0;
      end if;
      return Table_Ppn (Pool_Ppn, Owner_Tag (Space), 0);
   end Root_Ppn;

   procedure Ensure_Mid
     (S      : Space_Id;
      Index  : Entry_Index;
      Mid    : out Mid_Slot;
      Result : out U64)
   with
     Pre  => Invariant and then Ready and then Info (S).Active and then Index in 4 .. 255,
     Post =>
       Invariant
       and then (Result = Status_Ok or else Result = Status_No_Space)
       and then Info (S).Active
       and then Info (S).Leaf_Used = Info'Old (S).Leaf_Used
       and then
         (if Result = Status_Ok
          then Points_Into (Pool (S) (0) (Index), Pool_Ppn, S, 1, U64 (Info (S).Mid_Used))
            and then Child_Slot (Pool (S) (0) (Index), S) = Mid
            and then U64 (Mid) - 1 < U64 (Info (S).Mid_Used))
   is
      Current : constant U64 := Pool (S) (0) (Index);
      Old_T   : constant Space_Tables := Pool (S) with Ghost;
      Old_I   : constant Space_Info := Info (S) with Ghost;
   begin
      Mid    := 1;
      Result := Status_Ok;
      Lemma_Root_Entry (Old_T, Old_I, Pool_Ppn, S, Kernel, Index);

      if Current = 0 then
         if Info (S).Mid_Used = 2 then
            Result := Status_No_Space;
            return;
         end if;

         Mid := Mid_Slot (1 + Table_Slot (Info (S).Mid_Used));
         Lemma_New_Pointer (Table_Ppn (Pool_Ppn, S, Mid));
         Pool (S) (0) (Index) := Table_Entry (Table_Ppn (Pool_Ppn, S, Mid));
         Info (S).Mid_Used := Info (S).Mid_Used + 1;

         Lemma_Add_Mid (Old_T, Pool (S), Old_I, Info (S), Pool_Ppn, S, Kernel, Index);
         Lemma_Same_Leaves (Old_T, Pool (S), S, Frame_Base, Frame_Count, Owner, Rights);
      else
         Mid := Mid_Slot (Ppn_Of (Current) - Table_Ppn (Pool_Ppn, S, 0));
      end if;
   end Ensure_Mid;

   procedure Ensure_Leaf
     (S      : Space_Id;
      Mid    : Mid_Slot;
      Index  : Entry_Index;
      Leaf   : out Leaf_Slot;
      Result : out U64)
   with
     Pre  =>
       Invariant
       and then Ready
       and then Info (S).Active
       and then U64 (Mid) - 1 < U64 (Info (S).Mid_Used),
     Post =>
       Invariant
       and then (Result = Status_Ok or else Result = Status_No_Space)
       and then Info (S).Active
       and then Info (S).Mid_Used = Info'Old (S).Mid_Used
       and then Pool (S) (0) = Pool'Old (S) (0)
       and then
         (for all X in Mid_Slot =>
            (for all E in Entry_Index =>
               (if X /= Mid or else E /= Index
                then Pool (S) (X) (E) = Pool'Old (S) (X) (E))))
       and then
         (if Result = Status_Ok
          then Points_Into (Pool (S) (Mid) (Index), Pool_Ppn, S, 3, U64 (Info (S).Leaf_Used))
            and then Child_Slot (Pool (S) (Mid) (Index), S) = Leaf
            and then U64 (Leaf) - 3 < U64 (Info (S).Leaf_Used))
   is
      Current : constant U64 := Pool (S) (Mid) (Index);
      Old_T   : constant Space_Tables := Pool (S) with Ghost;
      Old_I   : constant Space_Info := Info (S) with Ghost;
   begin
      Leaf   := 3;
      Result := Status_Ok;
      Lemma_Mid_Entry (Old_T, Old_I, Pool_Ppn, S, Kernel, Mid, Index);

      if Current = 0 then
         if Info (S).Leaf_Used = 5 then
            Result := Status_No_Space;
            return;
         end if;

         Leaf := Leaf_Slot (3 + Table_Slot (Info (S).Leaf_Used));
         Lemma_New_Pointer (Table_Ppn (Pool_Ppn, S, Leaf));
         Pool (S) (Mid) (Index) := Table_Entry (Table_Ppn (Pool_Ppn, S, Leaf));
         Info (S).Leaf_Used := Info (S).Leaf_Used + 1;

         Lemma_Add_Leaf (Old_T, Pool (S), Old_I, Info (S), Pool_Ppn, S, Kernel, Mid, Index);
         Lemma_Same_Leaves (Old_T, Pool (S), S, Frame_Base, Frame_Count, Owner, Rights);
         pragma Assert (Ppn_Of (Pool (S) (Mid) (Index)) = Table_Ppn (Pool_Ppn, S, Leaf));
      else
         Leaf := Leaf_Slot (Ppn_Of (Current) - Table_Ppn (Pool_Ppn, S, 0));
         pragma Assert (Pool (S) (Mid) (Index) = Current);
      end if;
      pragma Assert
        (Points_Into (Pool (S) (Mid) (Index), Pool_Ppn, S, 3, U64 (Info (S).Leaf_Used)));
   end Ensure_Leaf;

   --  Con el marco recién reservado y sin dueño, lo entrega a S y lo mapea.
   procedure Install_Leaf
     (S     : Space_Id;
      Leaf  : Leaf_Slot;
      Index : Entry_Index;
      Ppn   : U64;
      Perm  : Permission)
   with
     Pre  =>
       Invariant
       and then Ready
       and then Info (S).Active
       and then U64 (Leaf) - 3 < U64 (Info (S).Leaf_Used)
       and then Frame_In (Ppn, Frame_Base, Frame_Count)
       and then Owner (Frame_Number (Ppn - Frame_Base)) = No_Owner
       and then Count_Of (S) < Max_Owned,
     Post =>
       Invariant
       and then Info = Info'Old
       and then Frame_Owner_Is (Ppn, S)
       and then Pool (S) (Leaf) (Index) = User_Leaf (Ppn, Perm)
       and then Pool (S) (0) = Pool'Old (S) (0)
       and then (for all X in Mid_Slot => Pool (S) (X) = Pool'Old (S) (X))
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Frame_Owner_Is);
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Lists_Ok);
      F     : constant Frame_Number := Frame_Number (Ppn - Frame_Base);
      Old_T : constant Space_Tables := Pool (S) with Ghost;
      Old_O : constant Owner_Map := Owner with Ghost;
   begin
      Lemma_User_Leaf (Ppn, Perm);

      --  El marco entra al final de la lista del espacio.
      Count_Of (S) := Count_Of (S) + 1;
      List (S) (Count_Of (S)) := F;
      Slot_Of (F) := Count_Of (S);
      Owner (F) := S;
      pragma Assert (Lists_Ok);
      Lemma_Other_Owners (Pool, S, Frame_Base, Frame_Count, Old_O, Owner, F, Rights);
      Lemma_Other_Owner (Old_T, S, Frame_Base, Frame_Count, Old_O, Owner, F, Rights);

      Pool (S) (Leaf) (Index) := User_Leaf (Ppn, Perm);
      Lemma_Install_Structure (Old_T, Pool (S), Info (S), Pool_Ppn, S, Kernel, Leaf, Index);
      Lemma_Install_Owned
        (Old_T, Pool (S), S, Frame_Base, Frame_Count, Owner, Leaf, Index, Ppn, Rights);
   end Install_Leaf;

   --  Última fase de Map_New: reserva el marco y lo instala en una entrada libre.
   procedure Allocate_And_Install
     (S     : Space_Id;
      Leaf  : Leaf_Slot;
      Index : Entry_Index;
      Perm  : Permission;
      Code  : out U64)
   with
     Pre  =>
       Invariant
       and then Ready
       and then Info (S).Active
       and then U64 (Leaf) - 3 < U64 (Info (S).Leaf_Used),
     Post =>
       Invariant
       and then Info = Info'Old
       and then Pool (S) (0) = Pool'Old (S) (0)
       and then (for all X in Mid_Slot => Pool (S) (X) = Pool'Old (S) (X))
       and then
         (Code < Page_Bytes
          or else
            (Code mod Page_Bytes = 0
             and then Code / Page_Bytes < Max_Ppn
             and then Frame_Owner_Is (Code / Page_Bytes, S)
             and then Pool (S) (Leaf) (Index) = User_Leaf (Code / Page_Bytes, Perm)))
   is
      Address : Frame_Gate.U64;
      Ppn     : U64;
      Ignored : Frame_Gate.U64;
   begin
      if Pool (S) (Leaf) (Index) /= 0 then
         Code := Status_Conflict;
         return;
      end if;

      --  No puede pasar (hay un marco por entrada hoja), pero se comprueba.
      if Count_Of (S) = Max_Owned then
         Code := Status_No_Space;
         return;
      end if;

      Address := Frame_Gate.Alloc;
      Code := U64 (Address);
      if Code = 0 then
         Code := Status_No_Frames;
         return;
      end if;

      --  El asignador es de otro módulo: su resultado también se comprueba.
      Ppn := Code / Page_Bytes;
      if Code mod Page_Bytes /= 0
        or else not Frame_In (Ppn, Frame_Base, Frame_Count)
        or else Owner (Frame_Number (Ppn - Frame_Base)) /= No_Owner
      then
         Ignored := Frame_Gate.Free (Address);
         pragma Unreferenced (Ignored);
         Code := Status_Internal;
         return;
      end if;

      Install_Leaf (S, Leaf, Index, Ppn, Perm);
   end Allocate_And_Install;

   function Map_New (Space, Va, Perm : U64) return U64 is
      S      : Space_Id;
      Mid    : Mid_Slot;
      Leaf   : Leaf_Slot;
      Result : U64;
   begin
      if not Ready
        or else not Valid_Space (Space)
        or else not Valid_Perm (Perm)
        or else not In_User_Window (Va)
        or else Va mod Page_Bytes /= 0
      then
         return Status_Invalid;
      end if;

      S := Owner_Tag (Space);
      if not Info (S).Active then
         return Status_Invalid;
      end if;

      Ensure_Mid (S, Root_Index (Va), Mid, Result);
      if Result /= Status_Ok then
         return Result;
      end if;

      Ensure_Leaf (S, Mid, Mid_Index (Va), Leaf, Result);
      if Result /= Status_Ok then
         return Result;
      end if;

      pragma Assert (Own_Table (Pool (S) (0) (Root_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (0) (Root_Index (Va)), S) = Mid);
      pragma Assert (Own_Table (Pool (S) (Mid) (Mid_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (Mid) (Mid_Index (Va)), S) = Leaf);

      Allocate_And_Install (S, Leaf, Low_Index (Va), To_Permission (Perm), Result);

      pragma Assert (Own_Table (Pool (S) (0) (Root_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (0) (Root_Index (Va)), S) = Mid);
      pragma Assert (Own_Table (Pool (S) (Mid) (Mid_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (Mid) (Mid_Index (Va)), S) = Leaf);
      pragma Assert (Walk (S, Va) = Pool (S) (Leaf) (Low_Index (Va)));
      return Result;
   end Map_New;

   --  Entrega el dispositivo D a S y lo mapea en una entrada libre.
   procedure Install_Device
     (S     : Space_Id;
      D     : Device_Id;
      Leaf  : Leaf_Slot;
      Index : Entry_Index)
   with
     Pre  =>
       Invariant
       and then Ready
       and then Info (S).Active
       and then U64 (Leaf) - 3 < U64 (Info (S).Leaf_Used)
       and then Device_Owner (D) = No_Owner,
     Post =>
       Invariant
       and then Info = Info'Old
       and then Device_Owner = (Device_Owner'Old with delta D => S)
       and then Pool (S) (Leaf) (Index) = User_Leaf (Device_Ppn (D), Read_Write)
       and then Pool (S) (0) = Pool'Old (S) (0)
       and then (for all X in Mid_Slot => Pool (S) (X) = Pool'Old (S) (X))
   is
      Old_T   : constant Space_Tables := Pool (S) with Ghost;
      Old_Dev : constant Access_Rights := Rights with Ghost;
   begin
      Lemma_User_Leaf (Device_Ppn (D), Read_Write);

      Device_Owner (D) := S;
      Lemma_Device_Others
        (Pool, S, Frame_Base, Frame_Count, Owner, Old_Dev, Rights);
      Lemma_Device_Change (Old_T, S, Frame_Base, Frame_Count, Owner, Old_Dev, Rights);

      Pool (S) (Leaf) (Index) := User_Leaf (Device_Ppn (D), Read_Write);
      Lemma_Install_Structure (Old_T, Pool (S), Info (S), Pool_Ppn, S, Kernel, Leaf, Index);
      pragma Assert (Owned_Ppn (Device_Ppn (D), S, Frame_Base, Frame_Count, Owner, Rights));
      Lemma_Install_Owned
        (Old_T, Pool (S), S, Frame_Base, Frame_Count, Owner, Leaf, Index, Device_Ppn (D), Rights);
   end Install_Device;

   function Map_Device (Space, Device, Va : U64) return U64 is
      D      : Device_Id;
      S      : Space_Id;
      Mid    : Mid_Slot;
      Leaf   : Leaf_Slot;
      Result : U64;
   begin
      if not Ready
        or else not Valid_Space (Space)
        or else not Valid_Device (Device)
        or else not In_User_Window (Va)
        or else Va mod Page_Bytes /= 0
      then
         return Status_Invalid;
      end if;

      S := Owner_Tag (Space);
      D := Device_Id (Device);
      if not Info (S).Active then
         return Status_Invalid;
      end if;

      if Device_Owner (D) /= No_Owner then
         return Status_Conflict;
      end if;

      Ensure_Mid (S, Root_Index (Va), Mid, Result);
      if Result /= Status_Ok then
         return Result;
      end if;

      Ensure_Leaf (S, Mid, Mid_Index (Va), Leaf, Result);
      if Result /= Status_Ok then
         return Result;
      end if;

      if Pool (S) (Leaf) (Low_Index (Va)) /= 0 then
         return Status_Conflict;
      end if;

      pragma Assert (Own_Table (Pool (S) (0) (Root_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (0) (Root_Index (Va)), S) = Mid);
      pragma Assert (Own_Table (Pool (S) (Mid) (Mid_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (Mid) (Mid_Index (Va)), S) = Leaf);

      Install_Device (S, D, Leaf, Low_Index (Va));

      pragma Assert (Own_Table (Pool (S) (0) (Root_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (0) (Root_Index (Va)), S) = Mid);
      pragma Assert (Own_Table (Pool (S) (Mid) (Mid_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (Mid) (Mid_Index (Va)), S) = Leaf);
      pragma Assert (Walk (S, Va) = Pool (S) (Leaf) (Low_Index (Va)));
      return Status_Ok;
   end Map_Device;

   function Translate (Space, Va, Mode : U64) return U64 is
      E      : U64;
      Result : U64;
   begin
      if not Valid_Space (Space)
        or else not In_User_Window (Va)
        or else (Mode /= Access_Read and then Mode /= Access_Write)
      then
         return 0;
      end if;

      E := Walk (Owner_Tag (Space), Va);
      if E = 0 then
         return 0;
      end if;

      Lemma_Walk_Owned (Owner_Tag (Space), Va);

      --  Leer un registro de un dispositivo tiene efectos: el kernel nunca lo hace.
      if Is_Device_Ppn (Ppn_Of (E)) then
         return 0;
      end if;

      if Mode = Access_Write and then (E and Flag_W) = 0 then
         return 0;
      end if;

      pragma Assert (Ppn_Of (E) < Max_Ppn);
      Result := Ppn_Of (E) * Page_Bytes;
      Lemma_Page_Address (Ppn_Of (E));
      pragma Assert (Result / Page_Bytes = Ppn_Of (E));
      pragma Assert (Frame_Owner_Is (Result / Page_Bytes, Owner_Tag (Space)));
      return Result;
   end Translate;

   ---------------------------------------------------------------------------
   --  Regiones compartidas.
   ---------------------------------------------------------------------------

   --  Un marco recién reservado y sin dueño pasa al final de la lista de R.
   procedure Add_Region_Frame (R : Region_Tag; F : Frame_Number) with
     Pre  =>
       Invariant
       and then Owner (F) = No_Owner
       and then Count_Of (R) < Max_Region_Pages
       and then (for all S in Space_Id => not Attached (R, S)),
     Post =>
       Invariant
       and then Count_Of (R) = Count_Of'Old (R) + 1
       and then Attached = Attached'Old
       and then Pool = Pool'Old
       and then Info = Info'Old
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Lists_Ok);
      Old_O : constant Owner_Map := Owner with Ghost;
   begin
      Count_Of (R) := Count_Of (R) + 1;
      List (R) (Count_Of (R)) := F;
      Slot_Of (F) := Count_Of (R);
      Owner (F) := R;
      pragma Assert (Lists_Ok);
      Lemma_Other_Owners (Pool, R, Frame_Base, Frame_Count, Old_O, Owner, F, Rights);
   end Add_Region_Frame;

   --  Devuelve al asignador los marcos de una región a la que nadie está unido.
   procedure Release_Region (R : Region_Tag; Failed : out Boolean) with
     Pre  =>
       Invariant
       and then (for all S in Space_Id => not Attached (R, S)),
     Post =>
       Invariant
       and then Count_Of (R) = 0
       and then Attached = Attached'Old
       and then Pool = Pool'Old
       and then Info = Info'Old
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Lists_Ok);
      Status : Frame_Gate.U64;
   begin
      Failed := False;
      for I in 1 .. Count_Of (R) loop
         pragma Loop_Invariant
           (for all X in Space_Id =>
              Frames_Owned (Pool (X), X, Frame_Base, Frame_Count, Owner, Rights));
         pragma Loop_Invariant
           (for all J in I .. Count_Of (R) =>
              Owner (List (R) (J)) = R and then Slot_Of (List (R) (J)) = J);
         pragma Loop_Invariant
           (for all G in Frame_Number =>
              (if Owner (G) = R
               then Slot_Of (G) in I .. Count_Of (R) and then List (R) (Slot_Of (G)) = G));
         pragma Loop_Invariant
           (for all G in Frame_Number =>
              (if Owner (G) /= No_Owner and then Owner (G) /= R
               then Slot_Of (G) in 1 .. Count_Of (Owner (G))
                 and then List (Owner (G)) (Slot_Of (G)) = G));
         pragma Loop_Invariant
           (for all X in Holder_Id =>
              (if X /= R
               then (for all J in 1 .. Count_Of (X) =>
                       Owner (List (X) (J)) = X and then Slot_Of (List (X) (J)) = J)));
         pragma Loop_Invariant (Attached = Attached'Loop_Entry);
         pragma Loop_Invariant (Pool = Pool'Loop_Entry and then Info = Info'Loop_Entry);

         declare
            F     : constant Frame_Number := List (R) (I);
            Old_O : constant Owner_Map := Owner with Ghost;
         begin
            Owner (F) := No_Owner;
            Lemma_Other_Owners (Pool, R, Frame_Base, Frame_Count, Old_O, Owner, F, Rights);
            Status := Frame_Gate.Free
              (Frame_Gate.U64 ((Frame_Base + U64 (F)) * Page_Bytes));
            if Status /= Frame_Gate.Status_Ok then
               Failed := True;
            end if;
         end;
      end loop;

      pragma Assert (for all G in Frame_Number => Owner (G) /= R);
      Count_Of (R) := 0;
      pragma Assert (Lists_Ok);
   end Release_Region;

   function Region_Create (Pages : U64) return U64 is
      R       : Region_Tag := Region_Tag'First;
      Found   : Boolean := False;
      Address : Frame_Gate.U64;
      Code    : U64;
      Ppn     : U64;
      Ignored : Frame_Gate.U64;
      Failed  : Boolean;
      pragma Unreferenced (Ignored);
   begin
      if not Ready or else Pages = 0 or else Pages > U64 (Max_Region_Pages) then
         return 0;
      end if;

      for X in Region_Tag loop
         if Count_Of (X) = 0 then
            R := X;
            Found := True;
            exit;
         end if;
      end loop;
      if not Found then
         return 0;
      end if;
      pragma Assert (for all S in Space_Id => not Attached (R, S));

      for I in 1 .. Pages loop
         pragma Loop_Invariant (Invariant);
         pragma Loop_Invariant (Ready);
         pragma Loop_Invariant (U64 (Count_Of (R)) = I - 1);
         pragma Loop_Invariant (for all S in Space_Id => not Attached (R, S));

         Address := Frame_Gate.Alloc;
         Code := U64 (Address);
         Ppn := Code / Page_Bytes;
         if Code = 0
           or else Code mod Page_Bytes /= 0
           or else not Frame_In (Ppn, Frame_Base, Frame_Count)
           or else Owner (Frame_Number (Ppn - Frame_Base)) /= No_Owner
         then
            --  Sin marcos (o un resultado que no cuadra): no se queda con nada.
            if Code /= 0 then
               Ignored := Frame_Gate.Free (Address);
            end if;
            pragma Warnings
              (GNATprove, Off, "*is set by*but not used after the call",
               Reason => "si además falla una liberación, Region_Create falla igual");
            Release_Region (R, Failed);
            pragma Warnings (GNATprove, On, "*is set by*but not used after the call");
            return 0;
         end if;

         Add_Region_Frame (R, Frame_Number (Ppn - Frame_Base));
      end loop;

      pragma Assert (Pages_Of (R) = Pages);
      return U64 (R) - U64 (Max_Spaces);
   end Region_Create;

   function Region_Frame (Region, Page : U64) return U64 is
      R : Region_Tag;
   begin
      if not Valid_Region (Region) then
         return 0;
      end if;
      R := Tag_Of (Region);
      if Page >= U64 (Count_Of (R)) then
         return 0;
      end if;

      declare
         F : constant Frame_Number := List (R) (Owned_Index (Page + 1));
      begin
         pragma Assert (Frame_Base + U64 (F) < Max_Ppn);
         Lemma_Page_Address (Frame_Base + U64 (F));
         return (Frame_Base + U64 (F)) * Page_Bytes;
      end;
   end Region_Frame;

   function Region_Attach (Space, Region : U64) return U64 is
      S     : Space_Id;
      R     : Region_Tag;
      Old_R : constant Access_Rights := Rights with Ghost;
   begin
      if not Ready
        or else not Valid_Space (Space)
        or else not Valid_Region (Region)
      then
         return Status_Invalid;
      end if;

      S := Owner_Tag (Space);
      R := Tag_Of (Region);
      if not Info (S).Active or else Count_Of (R) = 0 then
         return Status_Invalid;
      end if;

      Attached (R, S) := True;
      Lemma_Links_Others (Pool, R, Frame_Base, Frame_Count, Owner, Old_R, Rights);
      return Status_Ok;
   end Region_Attach;

   --  Instala en una entrada libre una página de una región a la que S está unido.
   procedure Install_Shared
     (S     : Space_Id;
      Leaf  : Leaf_Slot;
      Index : Entry_Index;
      Ppn   : U64;
      Perm  : Permission)
   with
     Pre  =>
       Invariant
       and then Ready
       and then Info (S).Active
       and then U64 (Leaf) - 3 < U64 (Info (S).Leaf_Used)
       and then Ppn < Max_Ppn
       and then Owned_Ppn (Ppn, S, Frame_Base, Frame_Count, Owner, Rights),
     Post =>
       Invariant
       and then Info = Info'Old
       and then Attached = Attached'Old
       and then Count_Of = Count_Of'Old
       and then Pool (S) (Leaf) (Index) = User_Leaf (Ppn, Perm)
       and then Pool (S) (0) = Pool'Old (S) (0)
       and then (for all X in Mid_Slot => Pool (S) (X) = Pool'Old (S) (X))
   is
      Old_T : constant Space_Tables := Pool (S) with Ghost;
   begin
      Lemma_User_Leaf (Ppn, Perm);
      Pool (S) (Leaf) (Index) := User_Leaf (Ppn, Perm);
      Lemma_Install_Structure (Old_T, Pool (S), Info (S), Pool_Ppn, S, Kernel, Leaf, Index);
      Lemma_Install_Owned
        (Old_T, Pool (S), S, Frame_Base, Frame_Count, Owner, Leaf, Index, Ppn, Rights);
   end Install_Shared;

   --  Bits de una hoja de usuario de lectura o de lectura y escritura.
   procedure Lemma_Leaf_Flags (Ppn : U64; Perm : Permission) with
     Ghost,
     Global => null,
     Pre    => Ppn < Max_Ppn and then Perm /= Read_Execute,
     Post   =>
       (User_Leaf (Ppn, Perm) and Flag_X) = 0
       and then ((User_Leaf (Ppn, Perm) and Flag_W) /= 0) = (Perm = Read_Write)
   is
   begin
      null;
   end Lemma_Leaf_Flags;

   function Region_Map (Space, Region, Page, Va, Writable : U64) return U64 is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Lists_Ok);
      S      : Space_Id;
      R      : Region_Tag;
      Mid    : Mid_Slot;
      Leaf   : Leaf_Slot;
      Result : U64;
      Ppn    : U64;
      Perm   : Permission;
   begin
      if not Ready
        or else not Valid_Space (Space)
        or else not Valid_Region (Region)
        or else not In_User_Window (Va)
        or else Va mod Page_Bytes /= 0
      then
         return Status_Invalid;
      end if;

      S := Owner_Tag (Space);
      R := Tag_Of (Region);
      if not Info (S).Active
        or else not Attached (R, S)
        or else Page >= U64 (Count_Of (R))
      then
         return Status_Invalid;
      end if;

      Perm := (if Writable /= 0 then Read_Write else Read_Only);

      Ensure_Mid (S, Root_Index (Va), Mid, Result);
      if Result /= Status_Ok then
         return Result;
      end if;

      Ensure_Leaf (S, Mid, Mid_Index (Va), Leaf, Result);
      if Result /= Status_Ok then
         return Result;
      end if;

      if Pool (S) (Leaf) (Low_Index (Va)) /= 0 then
         return Status_Conflict;
      end if;

      declare
         F : constant Frame_Number := List (R) (Owned_Index (Page + 1));
      begin
         pragma Assert (Owner (F) = R);
         Ppn := Frame_Base + U64 (F);
         --  Las listas no dicen que el marco esté en el rango: se comprueba.
         if not Frame_In (Ppn, Frame_Base, Frame_Count) then
            return Status_Internal;
         end if;
         pragma Assert (Ppn < Max_Ppn);
         pragma Assert (Uses (Owner (Frame_Number (Ppn - Frame_Base)), S, Rights));
      end;

      pragma Assert (Own_Table (Pool (S) (0) (Root_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (0) (Root_Index (Va)), S) = Mid);
      pragma Assert (Own_Table (Pool (S) (Mid) (Mid_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (Mid) (Mid_Index (Va)), S) = Leaf);

      Install_Shared (S, Leaf, Low_Index (Va), Ppn, Perm);
      Lemma_User_Leaf (Ppn, Perm);
      Lemma_Leaf_Flags (Ppn, Perm);

      pragma Assert (Own_Table (Pool (S) (0) (Root_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (0) (Root_Index (Va)), S) = Mid);
      pragma Assert (Own_Table (Pool (S) (Mid) (Mid_Index (Va)), S));
      pragma Assert (Child_Slot (Pool (S) (Mid) (Mid_Index (Va)), S) = Leaf);
      pragma Assert (Walk (S, Va) = Pool (S) (Leaf) (Low_Index (Va)));
      pragma Assert (Walk (S, Va) = User_Leaf (Ppn, Perm));
      return Status_Ok;
   end Region_Map;

   function Region_Frame_For (Space, Region, Page : U64) return U64 is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Lists_Ok);
      R : Region_Tag;
   begin
      if not Valid_Space (Space) or else not Valid_Region (Region) then
         return 0;
      end if;
      R := Tag_Of (Region);
      if not Attached (R, Owner_Tag (Space)) or else Page >= U64 (Count_Of (R)) then
         return 0;
      end if;

      declare
         F : constant Frame_Number := List (R) (Owned_Index (Page + 1));
      begin
         pragma Assert (Owner (F) = R);
         --  Las listas no dicen que el marco esté en el rango: se comprueba.
         if U64 (F) >= Frame_Count then
            return 0;
         end if;
         pragma Assert (Frame_Base + U64 (F) < Max_Ppn);
         Lemma_Page_Address (Frame_Base + U64 (F));
         pragma Assert ((Frame_Base + U64 (F)) * Page_Bytes / Page_Bytes = Frame_Base + U64 (F));
         return (Frame_Base + U64 (F)) * Page_Bytes;
      end;
   end Region_Frame_For;

   function Region_In_Use (Region : U64) return U64 is
   begin
      if not Valid_Region (Region) then
         return 0;
      end if;
      for S in Space_Id loop
         if Attached (Tag_Of (Region), S) then
            return 1;
         end if;
         pragma Loop_Invariant
           (for all X in Space_Id'First .. S => not Attached (Tag_Of (Region), X));
      end loop;
      return 0;
   end Region_In_Use;

   function Region_Free (Region : U64) return U64 is
      R      : Region_Tag;
      Failed : Boolean;
   begin
      if not Ready or else not Valid_Region (Region) then
         return Status_Invalid;
      end if;
      R := Tag_Of (Region);
      if Count_Of (R) = 0 then
         return Status_Invalid;
      end if;
      for S in Space_Id loop
         if Attached (R, S) then
            return Status_Conflict;
         end if;
         pragma Loop_Invariant (for all X in Space_Id'First .. S => not Attached (R, X));
      end loop;

      Release_Region (R, Failed);
      return (if Failed then Status_Internal else Status_Ok);
   end Region_Free;

   --  En un espacio activo, las tablas que no están en uso están a cero.
   --  S deja el dispositivo D: los demás espacios siguen con lo que tenían.
   procedure Release_Device (S : Space_Id; D : Device_Id) with
     Pre  =>
       Device_Owner (D) = S
       and then
         (for all X in Space_Id =>
            (if X /= S then Frames_Owned (Pool (X), X, Frame_Base, Frame_Count, Owner, Rights))),
     Post =>
       Device_Owner = (Device_Owner'Old with delta D => No_Owner)
       and then
         (for all X in Space_Id =>
            (if X /= S then Frames_Owned (Pool (X), X, Frame_Base, Frame_Count, Owner, Rights)))
   is
      Old_Dev : constant Access_Rights := Rights with Ghost;
   begin
      Device_Owner (D) := No_Owner;
      Lemma_Device_Others (Pool, S, Frame_Base, Frame_Count, Owner, Old_Dev, Rights);
   end Release_Device;

   procedure Lemma_Unused_Zero
     (T    : Space_Tables;
      I    : Space_Info;
      Base : U64;
      S    : Space_Id;
      K    : Kernel_Root)
   with
     Ghost,
     Pre  => I.Active and then Structure_Ok (T, I, Base, S, K),
     Post =>
       (for all X in Table_Slot =>
          (if not (X = 0
                   or else (X in Mid_Slot and then U64 (X) - 1 < U64 (I.Mid_Used))
                   or else (X in Leaf_Slot and then U64 (X) - 3 < U64 (I.Leaf_Used)))
           then (for all E in Entry_Index => T (X) (E) = 0)))
   is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Structure_Ok);
   begin
      null;
   end Lemma_Unused_Zero;

   function Destroy (Space : U64) return U64 is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Lists_Ok);
      S      : Space_Id;
      Failed : Boolean := False;
      Status : Frame_Gate.U64;
   begin
      if not Ready or else not Valid_Space (Space) then
         return Status_Invalid;
      end if;

      S := Owner_Tag (Space);
      if not Info (S).Active then
         return Status_Invalid;
      end if;

      --  Exactamente los marcos de la lista: Count_Of (S) vueltas.
      for I in 1 .. Count_Of (S) loop
         pragma Loop_Invariant
           (for all X in Space_Id =>
              (if X /= S
               then Frames_Owned (Pool (X), X, Frame_Base, Frame_Count, Owner, Rights)));
         pragma Loop_Invariant
           (for all J in I .. Count_Of (S) =>
              Owner (List (S) (J)) = S and then Slot_Of (List (S) (J)) = J);
         pragma Loop_Invariant
           (for all G in Frame_Number =>
              (if Owner (G) = S
               then Slot_Of (G) in I .. Count_Of (S) and then List (S) (Slot_Of (G)) = G));
         pragma Loop_Invariant
           (for all G in Frame_Number =>
              (if Owner (G) /= No_Owner and then Owner (G) /= S
               then Slot_Of (G) in 1 .. Count_Of (Owner (G))
                 and then List (Owner (G)) (Slot_Of (G)) = G));
         pragma Loop_Invariant
           (for all X in Holder_Id =>
              (if X /= S
               then (for all J in 1 .. Count_Of (X) =>
                       Owner (List (X) (J)) = X and then Slot_Of (List (X) (J)) = J)));

         declare
            F     : constant Frame_Number := List (S) (I);
            Old_O : constant Owner_Map := Owner with Ghost;
         begin
            Owner (F) := No_Owner;
            Lemma_Other_Owners (Pool, S, Frame_Base, Frame_Count, Old_O, Owner, F, Rights);
            Status := Frame_Gate.Free
              (Frame_Gate.U64 ((Frame_Base + U64 (F)) * Page_Bytes));
            if Status /= Frame_Gate.Status_Ok then
               Failed := True;
            end if;
         end;
      end loop;

      pragma Assert (for all G in Frame_Number => Owner (G) /= S);
      Count_Of (S) := 0;
      pragma Assert (Lists_Ok);

      --  Solo se borran las tablas en uso: las demás ya están a cero. Borrar
      --  las ocho era la mayor parte de destruir un proceso pequeño.
      declare
         Old_T : constant Space_Tables := Pool (S) with Ghost;
         Zero  : constant Page_Table := (others => 0);
      begin
         Lemma_Unused_Zero (Old_T, Info (S), Pool_Ppn, S, Kernel);
         for X in Table_Slot loop
            if X = 0
              or else (X in Mid_Slot and then U64 (X) - 1 < U64 (Info (S).Mid_Used))
              or else (X in Leaf_Slot and then U64 (X) - 3 < U64 (Info (S).Leaf_Used))
            then
               Pool (S) (X) := Zero;
            end if;
            pragma Loop_Invariant
              (for all Y in Table_Slot'First .. X =>
                 (for all E in Entry_Index => Pool (S) (Y) (E) = 0));
            pragma Loop_Invariant
              (for all Y in Table_Slot =>
                 (if Y > X then Pool (S) (Y) = Old_T (Y)));
            pragma Loop_Invariant
              (for all Z in Space_Id =>
                 (if Z /= S then Pool (Z) = Pool'Loop_Entry (Z)));
         end loop;
         pragma Assert (Is_Zero (Pool (S)));
      end;
      Info (S) := Empty_Info;

      for D in Device_Id loop
         if Device_Owner (D) = S then
            Release_Device (S, D);
         end if;
         pragma Loop_Invariant (for all E in Device_Id'First .. D => Device_Owner (E) /= S);
         pragma Loop_Invariant
           (for all X in Space_Id =>
              (if X /= S then Frames_Owned (Pool (X), X, Frame_Base, Frame_Count, Owner, Rights)));
         pragma Loop_Invariant (Is_Zero (Pool (S)));
         pragma Loop_Invariant (Bounds_Ok and then Lists_Ok and then Regions_Ok);
      end loop;

      --  Deja de estar unido a toda región: sus tablas ya están a cero.
      declare
         Old_R : constant Access_Rights := Rights with Ghost;
      begin
         for R in Region_Tag loop
            Attached (R, S) := False;
            pragma Loop_Invariant (for all Q in Region_Tag'First .. R => not Attached (Q, S));
            pragma Loop_Invariant
              (for all Q in Region_Tag =>
                 (for all X in Space_Id =>
                    (if X /= S then Attached (Q, X) = Old_R.Links (Q, X))));
            pragma Loop_Invariant
              (for all Q in Region_Tag =>
                 (if Old_R.Links (Q, S) = False then Attached (Q, S) = False));
         end loop;
         Lemma_Links_Others (Pool, S, Frame_Base, Frame_Count, Owner, Old_R, Rights);
      end;

      Lemma_Zero_Is_Ok (Pool (S), Info (S), Pool_Ppn, S, Kernel);
      Lemma_Zero_Owns_Nothing (Pool (S), S, Frame_Base, Frame_Count, Owner, Rights);

      return (if Failed then Status_Internal else Status_Ok);
   end Destroy;

begin
   --  Solo existe para la demostración: el código fantasma no se compila.
   Lemma_Initial_State;
   Lemma_No_Owner_Lists;
end User_Space;
