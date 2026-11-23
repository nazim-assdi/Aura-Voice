from pydantic import BaseModel


class SpeechVoice(BaseModel):
    id: str
    name: str
    locale: str
    gender: str
