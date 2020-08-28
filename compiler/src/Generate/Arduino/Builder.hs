{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wall #-}

module Generate.Arduino.Builder
  ( Expr (..),
    stmtToBuilder,
    exprToBuilder,
    Stmt (..),
    PrefixOp (..),
    InfixOp (..),
  )
where

import qualified Data.ByteString as BS
import Data.ByteString.Builder as B
import qualified Data.Int as I
import qualified Data.List as List
import Generate.Arduino.Name (Name)
import qualified Generate.Arduino.Name as Name

-- Expressions
data Expr
  = String Builder
  | Ref Name
  | Bool Bool
  | Integer Builder
  | Int Int
  | Double Builder
  | If Expr Expr Expr
  | Prefix PrefixOp Expr
  | Class Name [Expr]
  | Struct [(Name, Expr)]
  | Call Expr [Expr]
  | Infix InfixOp Expr Expr
  | Function (Maybe Name) [Name] [Stmt]
  | Enum Name Expr
  | CoreRef Name
  | Access Expr Name

-- STATEMENTS
data Stmt
  = Block [Stmt]
  | EmptyStmt
  | Var String Name Expr
  | Decl String Builder
  | Const Expr
  | Return Expr
  | IfStmt Expr Stmt Stmt
  | WhileStmt Expr Stmt
  | FunctionStmt Name [Name] [Stmt]
  | EnumStmt Name Expr
  | PlaceholderStmt

-- Converts a datatype in form of a String to the equivelant C-datatype.
-- Also returned as a String.
prettyDataType :: String -> Builder
prettyDataType dataType =
  case dataType of
    "String" -> "string"
    "Bool" -> "bool"
    "Integer" -> "int"
    "Double" -> "double"
    "Void" -> "void"
    "Enum" -> "enum"
    -- Dummy case used because type information is missing
    "any" -> "arx::shared_ptr<ElmValue>"

stmtToBuilder :: Stmt -> Builder
stmtToBuilder stmts = pretty levelZero stmts

--This function takes a Stmt and converts it into a C-program as a string.
pretty :: Level -> Stmt -> Builder
pretty level@(Level indent nextLevel@(Level nextIndent nextNextLevel)) statement =
  case statement of
    Block array -> mconcat (map (pretty level) array)
    EmptyStmt -> error "Not supported EmptyStmt"
    PlaceholderStmt -> ""
    Var dataType name expr ->
      case expr of
        Function _ _ _ ->
          mconcat
            [ indent,
              prettyDataType dataType,
              " ",
              Name.toBuilder name,
              prettyExpr level expr
            ]
        CoreRef subname ->
          mconcat
            [ indent,
              "#define ",
              Name.toBuilder name,
              " ",
              Name.toBuilder subname,
              "\n\n"
            ]
        _ ->
          mconcat
            [ indent,
              prettyDataType dataType,
              " ",
              Name.toBuilder name,
              " =\n",
              nextIndent,
              prettyExpr nextNextLevel expr,
              ";\n\n"
            ]
    Decl dataType name -> mconcat ["\n", prettyDataType dataType, " ", name]
    Const constExpr -> mconcat ["const ", prettyExpr nextLevel constExpr, ";\n"]
    Return expr -> mconcat [indent, "return ", prettyExpr nextLevel expr, ";\n"]
    IfStmt condition thenStmt elseStmt ->
      mconcat
        [ "(",
          prettyExpr nextLevel condition,
          ") ? ",
          pretty nextLevel thenStmt,
          " : ",
          pretty nextLevel elseStmt
        ]
    WhileStmt condition loopStmt ->
      mconcat
        [ "while (",
          prettyExpr nextLevel condition,
          ") {\n",
          pretty nextLevel loopStmt,
          "}"
        ]
    FunctionStmt name args stmts ->
      mconcat
        [ Name.toBuilder name,
          "( void* args ) {\n",
          indent,
          "void* tmp0;",
          argsToBuilder args indent,
          fromStmtBlock nextLevel stmts,
          "}\n"
        ]
    EnumStmt name exprs -> error "Not supported EnumStmt"

fromStmtBlock :: Level -> [Stmt] -> Builder
fromStmtBlock level stmts = mconcat (map (pretty level) stmts)

exprToBuilder :: Expr -> Builder
exprToBuilder expr = prettyExpr levelZero expr

--Converts an argument of the type Expr into a String.
prettyExpr :: Level -> Expr -> Builder
prettyExpr level@(Level indent nextLevel) expression =
  case expression of
    String string -> mconcat ["\"", string, "\""]
    Ref name -> Name.toBuilder name
    Bool bool -> "Utils::Bool(" <> if (bool) then "true" <> ")" else "false" <> ")"
    Int n -> B.intDec n
    Double double -> "Utils::Float(" <> double <> ")"
    If infixExpr expr1 expr2 ->
      mconcat
        [ "Utils::GetBool(",
          prettyExpr nextLevel infixExpr,
          ") ? ",
          prettyExpr nextLevel expr1,
          " : ",
          prettyExpr nextLevel expr2
        ]
    Prefix prefixOperator expr1 ->
      mconcat [prettyPrefix prefixOperator, prettyExpr nextLevel expr1]
    Class name args ->
      mconcat ["Utils::Constr(", generateCtorArguments nextLevel name args, ")"]
    Struct fields ->
      mconcat ["Utils::Record(", generateRecordArguments nextLevel fields, ")"]
    Access expr field ->
      mconcat
        [ "Utils::GetField(",
          prettyExpr level expr,
          ", \"",
          Name.toBuilder field,
          "\")"
        ]
    Call expr1 exprs ->
      mconcat
        [ prettyExpr nextLevel expr1,
          "(\n",
          fromExprBlock nextLevel exprs,
          "\n",
          indent,
          ")"
        ]
    Infix infixoperator expr1 expr2 ->
      mconcat
        [ prettyExpr nextLevel expr1,
          " ",
          prettyInfix infixoperator,
          " ",
          prettyExpr nextLevel expr2
        ]
    Function maybeName args stmts ->
      mconcat
        [ maybe mempty Name.toBuilder maybeName,
          "(",
          commaSep (map (\x -> "arx::shared_ptr<ElmValue> " <> Name.toBuilder x) args),
          ") {\n",
          fromStmtBlock nextLevel stmts,
          "}\n\n"
        ]
    Enum name exprs ->
      mconcat ["enum ", Name.toBuilder name, prettyExpr nextLevel exprs, "\n"]

indexedMap :: (a -> I.Int8 -> b) -> [a] -> [b]
indexedMap f l = zipWith f l [0 ..]

argsToBuilder :: [Name.Name] -> Builder -> Builder
argsToBuilder args indent =
  mconcat
    ( indexedMap
        ( \x i ->
            indent
              <> "void* "
              <> Name.toBuilder x
              <> " = args["
              <> (B.int8Dec i)
              <> "];\n"
        )
        args
    )

commaSep :: [Builder] -> Builder
commaSep builders = mconcat (List.intersperse ", " builders)

fromExprBlock :: Level -> [Expr] -> Builder
fromExprBlock (Level indent nextLevel) exprs =
  mconcat (List.intersperse ",\n" (map (\e -> indent <> prettyExpr nextLevel e) exprs))

data InfixOp
  = OpAdd -- +
  | OpSub -- -
  | OpMul --  *
  | OpDiv -- /
  | OpMod -- %
  | OpEq -- ===
  | OpNe -- !==
  | OpLt -- <
  | OpLe -- <=
  | OpGt -- >
  | OpGe -- >=
  | OpAnd -- &&
  | OpOr --  ||
  | OpBitwiseAnd -- &
  | -- |
    OpBitwiseXor
  | OpBitwiseOr --  |
  | OpLShift -- <<
  | OpSpRShift -- >>
  | OpZfRShift -- >>>

data PrefixOp
  = PrefixNot -- !
  | PrefixNegate -- -
  | PrefixComplement -- ~+

prettyInfix :: InfixOp -> Builder
prettyInfix minfix =
  case minfix of
    OpAdd -> " + "
    OpSub -> " - "
    OpMul -> " * " --  *
    OpDiv -> " / " -- /
    OpMod -> " % "
    OpEq -> " == "
    OpNe -> " != "
    OpLt -> " < "
    OpLe -> " <= "
    OpGt -> " > "
    OpGe -> " >= "
    OpAnd -> " && "
    OpOr -> " || "
    OpBitwiseAnd -> " & "
    OpBitwiseXor -> " ^ "
    OpBitwiseOr -> " | "
    OpLShift -> " << "
    OpSpRShift -> " >> "
    OpZfRShift -> " >>> "

prettyPrefix :: PrefixOp -> Builder
prettyPrefix mprefix =
  case mprefix of
    PrefixNot -> "!"
    PrefixNegate -> "-"
    PrefixComplement -> "~+"

data Level
  = Level Builder Level

levelZero :: Level
levelZero = Level mempty (makeLevel 1 2)

makeLevel :: Int -> Int -> Level
makeLevel level levelIndent =
  Level
    (B.byteString (BS.replicate (level * levelIndent) 0x20))
    (makeLevel (level + 1) levelIndent)

generateStruct :: Level -> [(Name, Expr)] -> Builder
generateStruct level@(Level indent nextLevel) fields =
  let names = (map (\(name, expr) -> name) fields)
   in mconcat
        ( map
            (\name -> indent <> "arx::shared_ptr<ElmValue> " <> Name.toBuilder name <> ";\n")
            names
        )

generateCtorArguments :: Level -> Name -> [Expr] -> Builder
generateCtorArguments level name args =
  mconcat
    [ "\"",
      Name.toBuilder name,
      "\", ",
      generateArguments level args,
      ", ",
      B.intDec (length args)
    ]

generateRecordArguments :: Level -> [(Name, Expr)] -> Builder
generateRecordArguments level args =
  mconcat
    [ "new arx::shared_ptr<Entry>[",
      B.intDec (length args),
      "] {",
      mconcat (List.intersperse ", " (map (uncurry generateEntry) args)),
      "}, ",
      B.intDec (length args)
    ]
  where
    generateEntry field exp = "arx::shared_ptr<Entry>(new Entry{\"" <> Name.toBuilder field <> "\", " <> prettyExpr level exp <> "})"

generateArguments :: Level -> [Expr] -> Builder
generateArguments level args =
  mconcat
    [ "new arx::shared_ptr<ElmValue>[",
      B.intDec (length args),
      "] {",
      mconcat (List.intersperse ", " (map (prettyExpr level) args)),
      "}"
    ]
