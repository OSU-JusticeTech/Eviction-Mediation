-- Use the correct database (change if necessary)
USE [EVICTION_TEST];
GO

-- Ensure fresh creation by dropping existing tables (optional)
DROP TABLE IF EXISTS FileAttachments, FileDrafts, Messages, UserActivityLogs, PrimaryMessageGroups, SideMessageGroups, ConversationMediators, Mediators, MessageStrings, ScreeningQuestions, Users;
GO

-- Create Users Table
CREATE TABLE Users (
    UserID INT IDENTITY PRIMARY KEY,
    Email NVARCHAR(255) UNIQUE NOT NULL,
    Password NVARCHAR(255) NOT NULL,
    FName NVARCHAR(100) NOT NULL,
    LName NVARCHAR(100) NOT NULL,
    Role VARCHAR(20) CHECK (Role IN ('Admin', 'Mediator', 'Tenant', 'Landlord')),
    CreatedAt DATETIME DEFAULT GETDATE(),
    CompanyName NVARCHAR(255) NULL,
    AddressLine1 NVARCHAR(255) NULL,
    AddressLine2 NVARCHAR(255) NULL,
    City NVARCHAR(100) NULL,
    State NVARCHAR(2) NULL,
    ZipCode NVARCHAR(10) NULL
);
GO

-- Create ScreeningQuestions Table
CREATE TABLE ScreeningQuestions (
    ScreeningID INT IDENTITY PRIMARY KEY,
    UserID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE CASCADE,
    InterpreterNeeded BIT NOT NULL,
    InterpreterLanguage NVARCHAR(50) NULL,
    DisabilityAccommodation BIT NOT NULL,
    DisabilityExplanation NVARCHAR(MAX) NULL,
    ConflictOfInterest BIT NOT NULL,
    SpeakOnOwnBehalf BIT NOT NULL,
    NeedToConsult BIT NOT NULL,
    ConsultExplanation NVARCHAR(MAX) NULL,
    RelationshipToOtherParty NVARCHAR(MAX) NULL,
    Unsafe BIT NOT NULL,
    UnsafeExplanation NVARCHAR(MAX) NULL
);
GO

-- Create MessageStrings Table
CREATE TABLE MessageStrings (
    ConversationID INT IDENTITY PRIMARY KEY, 
    CreatedAt DATETIME DEFAULT GETDATE(),
    LastMessageSentDate DATETIME NULL,
    Role VARCHAR(20) CHECK (Role IN ('Primary', 'Side'))
);
GO

-- Create Mediators Table
CREATE TABLE Mediators (
    UserID INT PRIMARY KEY FOREIGN KEY REFERENCES Users(UserID) ON DELETE CASCADE,
    Available BIT NOT NULL,
    ActiveMediations INT DEFAULT 0,
    MediationCap INT NOT NULL
);
GO

-- Create ConversationMediators Table
CREATE TABLE ConversationMediators (
    MediatedConversationID INT IDENTITY PRIMARY KEY,
    MediatorID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE NO ACTION,
    ConversationID INT FOREIGN KEY REFERENCES MessageStrings(ConversationID) ON DELETE CASCADE,
    AssignedByAdminID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE NO ACTION,
    AssignedAt DATETIME DEFAULT GETDATE()
);
GO

-- Create SideMessageGroups Table
CREATE TABLE SideMessageGroups (
    UserID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE NO ACTION,
    MediatorID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE NO ACTION,
    ConversationID INT FOREIGN KEY REFERENCES MessageStrings(ConversationID) ON DELETE CASCADE,
    PRIMARY KEY (UserID, MediatorID, ConversationID)
);
GO

-- Create PrimaryMessageGroups Table
CREATE TABLE PrimaryMessageGroups (
    ConversationID INT PRIMARY KEY FOREIGN KEY REFERENCES MessageStrings(ConversationID) ON DELETE CASCADE,
    TenantID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE NO ACTION,
    LandlordID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE NO ACTION,
    CreatedAt DATETIME DEFAULT GETDATE(),
    LandlordScreeningID INT FOREIGN KEY REFERENCES ScreeningQuestions(ScreeningID) ON DELETE NO ACTION,
    TenantScreeningID INT FOREIGN KEY REFERENCES ScreeningQuestions(ScreeningID) ON DELETE NO ACTION,
    GoodFaith BIT DEFAULT 0,
    MediatorRequested BIT DEFAULT 0,
    MediatorAssigned BIT DEFAULT 0,
    MediatorID INT NULL FOREIGN KEY REFERENCES Users(UserID) ON DELETE SET NULL,
    EndOfConversationGoodFaithLandlord BIT DEFAULT 0,
    EndOfConversationGoodFaithTenant BIT DEFAULT 0
);
GO

-- Create Messages Table
CREATE TABLE Messages (
    MessageID INT IDENTITY PRIMARY KEY,
    ConversationID INT FOREIGN KEY REFERENCES MessageStrings(ConversationID) ON DELETE CASCADE,
    SenderID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE CASCADE,
    MessageDate DATETIME DEFAULT GETDATE(),
    Contents NVARCHAR(MAX) NOT NULL,
    RequiresMediatorReview BIT DEFAULT 0
);
GO

-- Create FileDrafts Table
CREATE TABLE FileDrafts (
    FileID INT IDENTITY PRIMARY KEY,
    CreatorID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE CASCADE,
    FileName NVARCHAR(255) NOT NULL,
    FileTypes NVARCHAR(100) NOT NULL,
    FileURLPath NVARCHAR(500) NOT NULL,
    CreatedAt DATETIME DEFAULT GETDATE(),
    UserDeletedAt DATETIME NULL
);
GO

-- Create FileAttachments Table
CREATE TABLE FileAttachments (
    FileID INT FOREIGN KEY REFERENCES FileDrafts(FileID) ON DELETE NO ACTION,
    MessageID INT FOREIGN KEY REFERENCES Messages(MessageID) ON DELETE NO ACTION,
    PRIMARY KEY (FileID, MessageID)
);
GO

-- Create UserActivityLogs Table
CREATE TABLE UserActivityLogs (
    LogID INT IDENTITY PRIMARY KEY,
    UserID INT FOREIGN KEY REFERENCES Users(UserID) ON DELETE CASCADE,
    ReferenceID INT NULL,  
    ActionType NVARCHAR(100) NOT NULL,
    ReferenceTable NVARCHAR(100) NOT NULL,
    TimeStamp DATETIME DEFAULT GETDATE(),
    IPAddress NVARCHAR(50) NOT NULL
);
GO
